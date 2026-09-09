#!/usr/bin/env python3
"""Hayes AT modem emulator with a socket DTE side.

The emulated machine's serial port connects here (unix socket or TCP). Dialling
either opens a TCP connection (BBS) or hands the raw line to pppd -- i.e. an ISP
terminal server, which is what a period PC actually dialled.

It also answers. --line gives the modem a phone number: an inbound TCP connection
rings the DTE, and the guest picks up with ATA (or automatically, once it has set
S0). That is the half NT4's Remote Access Server needs to *receive* calls, and it
is what lets one retro guest dial another.

Why not tcpser: its only socket DTE transport is ip232, which doubles 0xFF and
steals FF 00 / FF 01 to carry DTR. Every PPP frame starts FF 03, so ip232 eats
the link. This is 8-bit clean, and speaking unix sockets natively removes the
socat + pty sandwich (PVE's `-serial0 socket` plugs straight in).

One process is one modem on one line, because that is what a modem is. An ISP's
T1 into a rack of them is N processes on N ports; a single number in front of the
rack is a hunt group, which is a dispatcher this does not have.

No modem control lines: a QEMU socket chardev carries none, so DCD reads as
permanently asserted in the guest and the NO CARRIER result code is the only
carrier signal available. Guests set &C1 (DCD follows carrier) and &D2 (drop DTR
to hang up) anyway; neither can be honoured. Terminal software parses the result
code and copes. PPP cannot see the drop and falls back to LCP echo timeouts.

  qm set 102 -serial0 socket    # QEMU LISTENS on the socket, so we connect to it
  atmodem.py --connect /var/run/qemu-server/102.serial0 --phonebook pb.txt \
             --line 6102 --pppd 'pppd notty 10.62.0.1:10.62.0.2 require-pap lock'
"""

import argparse
import asyncio
import logging
import os
import re
import shlex
import socket
import tempfile
import time

# Hayes guard time: the silence required either side of +++ so that binary
# payloads containing +++ do not drop the link.
GUARD = 1.0
RING = 4.0  # seconds between RING results, as on a real line
RINGS = 8  # then the caller has given up

log = logging.getLogger("atmodem")

CODES = {"OK": 0, "CONNECT": 1, "RING": 2, "NO CARRIER": 3, "ERROR": 4, "BUSY": 7}


def digits(s):
    """Dialers emit ATDT9,1-555-1212 and friends; only the digits identify it."""
    return "".join(c for c in s if c.isdigit())


def load_phonebook(path):
    """86Box's own format on purpose -- <number><whitespace><target>, one per
    line -- so a single file serves both emulators. Target is host:port, or the
    literal 'ppp' to hand the call to pppd."""
    book = {}
    if not path:
        return book
    with open(path) as f:
        for line in f:
            parts = line.split("#", 1)[0].split()
            if len(parts) >= 2:
                book[digits(parts[0])] = parts[1]
    return book


class Phonebook:
    """A phonebook that re-reads itself when the file changes.

    Drop-in for the dict it replaces (both answer .get). Without this, editing a
    number means restarting the modem, which drops whatever call is up -- the
    single most annoying thing about operating this, and three lines to fix.
    """

    def __init__(self, path):
        self.path, self.mtime, self.book = path, None, {}

    def get(self, number):
        try:
            mtime = os.stat(self.path).st_mtime if self.path else None
        except OSError:
            mtime = None  # deleted mid-flight: keep serving the last good copy
        if mtime is not None and mtime != self.mtime:
            self.mtime, self.book = mtime, load_phonebook(self.path)
            log.info("phonebook reloaded: %d numbers", len(self.book))
        return self.book.get(number)


def parse(body):
    """Split an AT command line into (cmd, arg) pairs.

    The one subtlety worth code: extended commands are &X / %X / \\X, so a naive
    search for 'D' fires on the &D2 in every dialer's init string and tries to
    dial "2". Consume the prefix first. D itself swallows the rest of the line,
    per Hayes.
    """
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c in " \t":
            i += 1
            continue
        prefix = ""
        if c in "&%\\":
            prefix, i = c, i + 1
            if i >= len(body):
                break
            c = body[i]
        c, i = c.upper(), i + 1
        if not prefix and c == "D":
            out.append(("D", body[i:].strip()))
            break
        if not prefix and c == "S":
            # Sn=v is the one command whose register number matters (S0 is
            # auto-answer), so keep them apart: ("S0", "1"), not ("S", "1").
            m = re.match(r"(\d+)\s*=\s*(\d+)", body[i:])
            if m:
                i += m.end()
                out.append(("S" + m.group(1), m.group(2)))
                continue
        m = re.match(r"(\d*)\s*(?:=\s*(\d+))?", body[i:])
        i += m.end()
        out.append((prefix + c, m.group(2) if m.group(2) is not None else m.group(1)))
    return out


class Telnet:
    """A minimal telnet client, wrapping a peer stream with read/write/drain.

    A real telnetd opens with `IAC WILL ECHO, IAC WILL SGA`; raw-piped, those
    six bytes land on the guest's screen as garbage before the login prompt, and
    an un-doubled 0xFF corrupts any 8-bit transfer. Opt in per phonebook entry
    ('telnet:host[:port]') -- it MUST stay off for PPP and guest-to-guest links,
    where 0xFF is data, which is the same toggle 86Box gets wrong by default.
    """

    IAC, SE, SB, WILL, WONT, DO, DONT = 255, 240, 250, 251, 252, 253, 254
    AGREE = (1, 3)  # ECHO and SUPPRESS-GO-AHEAD: what a dumb terminal wants

    def __init__(self, reader, writer):
        self.r, self.w = reader, writer
        self.iac = self.sb = self.sb_iac = False
        self.verb = 0

    def _filter(self, data):
        """Split a chunk into (data for the guest, negotiation for the host)."""
        out, reply = bytearray(), bytearray()
        for b in data:
            if self.sb:  # skip subnegotiation payload until IAC SE
                if self.sb_iac and b == self.SE:
                    self.sb = False
                self.sb_iac = b == self.IAC and not self.sb_iac
            elif self.verb:  # this byte is the option the verb applies to
                if self.verb == self.WILL:
                    yes = self.DO if b in self.AGREE else self.DONT
                    reply += bytes((self.IAC, yes, b))
                elif self.verb == self.DO:
                    reply += bytes((self.IAC, self.WONT, b))  # we offer nothing
                self.verb = 0  # WONT/DONT need no answer
            elif self.iac:
                self.iac = False
                if b == self.IAC:
                    out.append(self.IAC)  # doubled 0xFF is literal data
                elif b in (self.WILL, self.WONT, self.DO, self.DONT):
                    self.verb = b
                elif b == self.SB:
                    self.sb, self.sb_iac = True, False
            elif b == self.IAC:
                self.iac = True
            else:
                out.append(b)
        return bytes(out), bytes(reply)

    async def read(self, n):
        while True:  # a chunk of pure negotiation yields nothing; go round again
            data = await self.r.read(n)
            if not data:
                return b""
            out, reply = self._filter(data)
            if reply:
                self.w.write(reply)
                await self.w.drain()
            if out:
                return out

    def write(self, data):
        self.w.write(data.replace(b"\xff", b"\xff\xff"))

    async def drain(self):
        await self.w.drain()


class Modem:
    def __init__(self, dte_r, dte_w, book, pppd, guard=GUARD, ring=RING, hook=None):
        self.dte_r, self.dte_w = dte_r, dte_w
        self.book, self.pppd, self.guard = book, pppd, guard
        self.ring_gap = ring  # not self.ring -- that name is the method below
        self.hook = hook  # called whenever the line goes on/off hook
        self.echo, self.verbose = True, True
        self.s = {}  # S registers; only S0 (auto-answer) is honoured
        self.staged = ""  # digits from ATD...; dialled in stages
        self.pushback = b""  # bytes after a "+++ATH"-style escape
        self.board = None  # set when this modem is one line of a switchboard
        self.peer = None  # (reader, writer, close) while off-hook
        self.incoming = None  # same, while the phone is ringing
        self.autoanswer = asyncio.Event()

    # -- DTE plumbing ------------------------------------------------------

    async def reply(self, text):
        # V1 is verbose words, V0 is the numeric code. Both are in the wild.
        log.info("DCE< %s", text)
        out = f"\r\n{text}\r\n" if self.verbose else f"{CODES[text]}\r"
        self.dte_w.write(out.encode())
        await self.dte_w.drain()

    async def _read_byte(self):
        """One byte from the DTE, but interruptible by auto-answer.

        Without the race, S0 auto-answer could never fire: between calls the
        modem sits blocked here, and a guest that has set S0 sends nothing at
        all -- it just waits for CONNECT. Returns None to mean "answer now".
        """
        if self.pushback:  # command that arrived glued to a +++ escape
            b, self.pushback = self.pushback[:1], self.pushback[1:]
            return b
        read = asyncio.ensure_future(self.dte_r.read(1))
        ring = asyncio.ensure_future(self.autoanswer.wait())
        done, pending = await asyncio.wait(
            {read, ring}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()  # safe: unread bytes stay in the StreamReader buffer
        if read in done:
            return read.result()  # a real byte wins; the event survives for next time
        self.autoanswer.clear()
        return None

    async def read_command(self):
        """Collect one CR-terminated line, honouring echo and backspace."""
        buf = bytearray()
        while True:
            b = await self._read_byte()
            if b is None:
                return "ATA"
            if not b:
                return None
            if self.echo:
                self.dte_w.write(b)
                await self.dte_w.drain()
            if b in (b"\r", b"\n"):
                if buf:
                    return buf.decode("latin-1")
                buf.clear()
            elif b == b"\x08":
                buf[-1:] = b""
            else:
                buf += b

    # -- command mode ------------------------------------------------------

    async def command(self, line):
        log.info("DTE> %s", line)
        if not line[:2].upper() == "AT":
            return await self.reply("ERROR")
        for cmd, arg in parse(line[2:]):
            if cmd == "D":
                return await self.dial(arg)
            if cmd == "A":
                return await self.answer()
            if cmd == "H":
                await self.hangup()
            elif cmd == "O" and self.peer:
                return await self.online()
            elif cmd == "E":
                self.echo = arg != "0"
            elif cmd == "V":
                self.verbose = arg != "0"
            elif cmd.startswith("S") and cmd[1:].isdigit():
                self.s[int(cmd[1:])] = int(arg or 0)
            # Everything else (Z, &F, &C1, &D2, S0=0, X4, ...) is accepted and
            # ignored on purpose: answering OK to unknown setup commands is what
            # makes an emulated modem work with dialers you have never seen.
        await self.reply("OK")

    async def dial(self, num):
        # A trailing ';' means "dial, then return to command state" -- Windows
        # TAPI opens every call with a bare `ATDT;` and only then sends the
        # digits, so answering NO CARRIER here kills the call before it starts.
        # Accumulate the staged digits and answer OK, as a real modem does.
        num = num.rstrip()
        if num.endswith(";"):
            self.staged += num[:-1]
            return await self.reply("OK")
        num, self.staged = self.staged + num, ""

        # D takes an optional dial modifier -- T(one) or P(ulse). Strip exactly
        # one, never lstrip(): dialling a host called "telnet.example.com" must
        # keep its 't'. Harmless for phonebook lookups, which go through
        # digits(), but it lands inside the hostname when dialling an address.
        if num[:1] in ("T", "P", "t", "p"):
            num = num[1:].strip()

        # Exact-digit lookup, same as 86Box: an outside-line prefix (ATDT9,555...)
        # is part of the number and will miss. Turn the prefix off in the dialer.
        target = self.book.get(digits(num)) or (num if ":" in num else None)
        if not target:
            return await self.reply("NO CARRIER")
        try:
            if target.startswith("vm:"):
                # Internal call to another line of this switchboard: no TCP hop,
                # no per-line port, and the callee really rings rather than
                # being handed raw bytes.
                name = target[len("vm:"):]
                if self.board is None or name not in self.board.lines:
                    return await self.reply("NO CARRIER")
                got = await self.board.call(name)
                if got is None:
                    return await self.reply("BUSY")
                # ponytail: CONNECT lands as soon as the callee starts RINGing,
                # not when it answers -- parity with the TCP path, where the
                # kernel completes connect() before anyone picks up. Data just
                # buffers until the callee's ATA. Wait on an answer event if a
                # guest ever objects.
                self.peer = (got[0], got[1], got[1].close)
            elif target.startswith("ssh:"):
                # Same subprocess shape as ppp. Deliberately NOT a generic
                # "exec:" target: a phonebook is the kind of file that ends up
                # editable by something other than root, and arbitrary argv in
                # it would be remote root execution wearing a phone number.
                dest = target[len("ssh:"):]
                host, sep, port = dest.rpartition(":")
                cmd = ["ssh", "-tt"] + (["-p", port] if sep else []) + [host if sep else dest]
                proc = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                )
                self.peer = (proc.stdout, proc.stdin, proc.kill)
            elif target == "ppp":
                proc = await asyncio.create_subprocess_exec(
                    *self.pppd,
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                )
                self.peer = (proc.stdout, proc.stdin, proc.kill)
            elif target.startswith("telnet:"):
                addr = target[len("telnet:"):]
                host, sep, port = addr.rpartition(":")
                if not sep:  # "telnet:bbs.example.com" -- the default port is the point
                    host, port = addr, "23"
                r, w = await asyncio.open_connection(host, int(port))
                tn = Telnet(r, w)
                self.peer = (tn, tn, w.close)
            else:
                host, _, port = target.rpartition(":")
                r, w = await asyncio.open_connection(host, int(port))
                self.peer = (r, w, w.close)
        except ConnectionRefusedError:
            # The far end is engaged: a busy line closes its listener, so the
            # refusal at connect() IS the busy tone. Must be caught before
            # OSError, which it subclasses.
            return await self.reply("BUSY")
        except (OSError, ValueError):
            return await self.reply("NO CARRIER")
        await self._hook()
        await self.reply("CONNECT")
        await self.online()

    async def _hook(self):
        """Tell the owner whether the line is engaged. A ringing line counts as
        engaged, same as a real one -- you do not get two calls on one pair."""
        if self.hook:
            await self.hook()

    async def ring(self, r, w):
        """An inbound call. Ring the DTE until it answers or the caller tires."""
        call = self.incoming = (r, w, w.close)
        await self._hook()
        for n in range(1, RINGS + 1):
            if self.incoming is not call:
                return  # answered, or hung up on
            await self.reply("RING")
            if self.s.get(0) and n >= self.s[0]:
                self.autoanswer.set()
                return
            await asyncio.sleep(self.ring_gap)
        if self.incoming is call:  # nobody picked up
            self.incoming = None
            w.close()
            await self._hook()

    async def answer(self):
        if not self.incoming:
            return await self.reply("NO CARRIER")
        self.peer, self.incoming = self.incoming, None
        await self.reply("CONNECT")
        await self.online()

    async def hangup(self):
        # ATH while ringing rejects the call, which is also how a real one behaves.
        for slot in ("peer", "incoming"):
            call = getattr(self, slot)
            if call:
                try:
                    call[2]()
                except (OSError, ProcessLookupError):
                    pass
                setattr(self, slot, None)
        await self._hook()

    # -- data mode ---------------------------------------------------------

    async def online(self):
        """Pump both directions until +++ escapes or the far end drops.

        Returns to command mode with the call still up on escape (ATO resumes,
        ATH hangs up), exactly as a real modem does.
        """
        peer_r, peer_w, _ = self.peer
        up = asyncio.ensure_future(self._dte_to_peer(peer_w))
        down = asyncio.ensure_future(self._peer_to_dte(peer_r))
        # Whichever direction ends first ends the call: waiting only on the DTE
        # side left the modem pumping into a dead peer after NO CARRIER, so it
        # never came back to command mode and swallowed every later command.
        done, pending = await asyncio.wait(
            {up, down}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        if up in done and up.result():  # +++ : the call stays up, ATO resumes it
            await self.reply("OK")

    async def _dte_to_peer(self, peer_w):
        """Guest -> far end. True if the guest escaped with +++."""
        held, last = b"", time.monotonic()
        while True:
            try:
                data = await asyncio.wait_for(
                    self.dte_r.read(4096), self.guard if held else None)
            except asyncio.TimeoutError:
                return True  # trailing guard elapsed: escaped
            if not data:
                return False
            if held:  # +++ was followed by traffic, so it was just data
                peer_w.write(held)
                held = b""
            if data.startswith(b"+++") and time.monotonic() - last >= self.guard:
                # NT4's RAS sends the escape and the command as ONE write --
                # "+++ATH" -- so matching only a bare b"+++" forwarded the whole
                # thing to the far end and the line could never be hung up.
                # A bare +++ still needs its trailing guard time; +++ followed by
                # a command is unambiguous, so escape at once and hand the rest
                # to the command reader.
                # ponytail: still assumes +++ arrives in one read. A dialer that
                # dribbles it byte-by-byte needs a per-byte timer instead.
                if len(data) == 3:
                    held = data
                    continue
                self.pushback = data[3:]
                return True
            try:
                peer_w.write(data)
                await peer_w.drain()
            except (ConnectionError, BrokenPipeError):
                return False
            last = time.monotonic()

    async def _peer_to_dte(self, peer_r):
        """Far end -> guest, until carrier drops."""
        while True:
            data = await peer_r.read(4096)
            if not data:
                break
            self.dte_w.write(data)
            await self.dte_w.drain()
        await self.hangup()
        await self.reply("NO CARRIER")

    async def run(self):
        while True:
            line = await self.read_command()
            if line is None:
                return await self.hangup()
            await self.command(line)


class Switchboard:
    """The lines this process owns, so a call between two of them never leaves it.

    Dialling a VM cannot be "just another target type": the answering guest needs
    a MODEM to hear RING and reply ATA, so wiring the caller straight to its
    serial socket would hand RAS raw bytes and it would never pick up. Only a
    process holding both ends can ring one on behalf of the other -- which is
    also where the hunt group and a real busy signal come from.
    """

    def __init__(self):
        self.lines = {}  # name -> Modem, while attached

    def free(self, name):
        modem = self.lines.get(name)
        return modem is not None and not modem.peer and not modem.incoming

    async def call(self, name):
        """Ring line `name`. Returns the caller's end, or None if it is engaged.

        A socketpair is the whole implementation: each modem gets one end and
        every path below -- the pump, 8-bit cleanliness, +++, NO CARRIER -- is
        the same code that carries an external call.
        """
        if not self.free(name):
            return None
        left, right = socket.socketpair()
        caller_r, caller_w = await asyncio.open_connection(sock=left)
        callee_r, callee_w = await asyncio.open_connection(sock=right)
        asyncio.ensure_future(self.lines[name].ring(callee_r, callee_w))
        return caller_r, caller_w


async def connect_dte(target):
    """Attach to a DTE that is listening: a unix socket path, or host:port."""
    if ":" in target:
        host, _, port = target.rpartition(":")
        return await asyncio.open_connection(host, int(port))
    return await asyncio.open_unix_connection(target)


async def serve(book, pppd, listen=None, connect=None, line=None, guard=GUARD,
                ring=RING, board=None, name=None):
    """Bring up one modem and, if --line was given, its phone line.

    Returns (dte_server_or_None, phone), where phone["port"] is the line's real
    port once it has been bound. With a `board`, the modem registers itself so
    other lines can ring it without going out over TCP.
    """
    state = {}
    phone = {"port": None if line is None else int(line), "srv": None}

    async def call(r, w):
        modem = state.get("modem")
        if modem is None or modem.peer or modem.incoming:
            return w.close()  # lost a race with hook(); refuse politely
        await modem.ring(r, w)

    async def hook():
        """Listen only while a modem is attached and on-hook.

        This is the busy signal. Closing the listener means a second caller is
        refused by the kernel at connect(), before anything can pretend the call
        went through -- whereas accepting and then closing would make the caller
        report CONNECT and immediately NO CARRIER. A ringing line is engaged too.
        """
        if phone["port"] is None:
            return
        modem = state.get("modem")
        free = modem is not None and not modem.peer and not modem.incoming
        if free and not phone["srv"]:
            # 0.0.0.0, not "": an unspecified host binds one socket per family,
            # and with port 0 each gets a *different* ephemeral port. v4-only is
            # honest here -- retronet has no IPv6 and the laptop's is broken.
            phone["srv"] = await asyncio.start_server(call, "0.0.0.0", phone["port"])
            phone["port"] = phone["srv"].sockets[0].getsockname()[1]
        elif not free and phone["srv"]:
            phone["srv"].close()
            phone["srv"] = None

    async def attach(r, w):
        modem = Modem(r, w, book, pppd, guard, ring, hook)
        modem.board = board
        state["modem"] = modem
        if board is not None:
            board.lines[name] = modem
        await hook()
        try:
            await modem.run()
        finally:
            state.pop("modem", None)
            if board is not None:
                board.lines.pop(name, None)
            await hook()
            w.close()

    if connect:
        # PVE's `-serial0 socket` leaves QEMU listening, so for a VM we are the
        # client. 86Box and plain TCP want the opposite; hence both modes.
        async def keep_attached():
            """Reattach forever: a guest reboot takes the chardev peer with it,
            and a switchboard that needs restarting after every VM reboot is not
            a service."""
            while True:
                try:
                    r, w = await connect_dte(connect)
                except OSError as exc:
                    log.warning("line %s: %s", name or connect, exc)
                    await asyncio.sleep(5)
                    continue
                log.info("line %s attached", name or connect)
                await attach(r, w)
                log.info("line %s dropped, reattaching", name or connect)
                await asyncio.sleep(1)

        asyncio.ensure_future(keep_attached())
        return None, phone

    if ":" in listen:
        host, _, port = listen.rpartition(":")
        dte = await asyncio.start_server(attach, host or "127.0.0.1", int(port))
    else:
        dte = await asyncio.start_unix_server(attach, listen)
    return dte, phone


async def selftest():
    """Covers the three things that are easy to get wrong: the link must be
    8-bit clean (what ip232 fails, and the reason this file exists), &D2 must
    not read as a dial command, and an inbound call must ring and be answerable
    both ways -- ATA, and S0 auto-answer."""
    # start_server only schedules the callback if it is a coroutine FUNCTION --
    # a lambda returning a coroutine is silently dropped. Pass _echo itself.
    echo = await asyncio.start_server(_echo, "127.0.0.1", 0)
    port = echo.sockets[0].getsockname()[1]
    dead = _closed_port()  # nothing listening: dialling it must give BUSY
    book = {"5551212": f"127.0.0.1:{port}", "5559999": f"127.0.0.1:{dead}"}
    dte, phone = await serve(book, [], listen="127.0.0.1:0", line=0,
                             guard=0.05, ring=0.05)
    r, w = await asyncio.open_connection(*dte.sockets[0].getsockname()[:2])

    # unknown setup commands must not be mistaken for a dial (&D2!)
    assert parse("&F&C1&D2S0=0") == [("&F", ""), ("&C", "1"), ("&D", "2"), ("S0", "0")]
    assert parse("DT9,1-555-1212") == [("D", "T9,1-555-1212")]
    assert digits("9,1-555-1212") == "915551212"

    w.write(b"AT&F&C1&D2S0=0\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")
    line = phone["port"]  # only bound once a modem attached, which OK just proved
    assert line, "line never opened"

    w.write(b"ATDT555-1212\r")
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n")

    payload = bytes(range(256)) * 4  # 0xFF and FF 03 included, deliberately
    w.write(payload)
    await w.drain()
    assert await r.readexactly(len(payload)) == payload, "link is not 8-bit clean"

    await asyncio.sleep(0.2)  # leading guard
    w.write(b"+++")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n"), "+++ did not escape"
    w.write(b"ATH\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")

    # the real Win98 dial sequence: init string, then a staged dial
    w.write(b"ATE0V1&C1&D2S0=0\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n"), "Win98 init string rejected"
    w.write(b"ATDT;\r")           # TAPI opens the call with no digits at all
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n"), "ATDT; must be OK, not NO CARRIER"
    w.write(b"ATDT555-1212\r")    # ...and only then dials
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n")
    await asyncio.sleep(0.2)      # data mode now: escape before ATH is a command
    w.write(b"+++")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")
    w.write(b"ATH\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")

    # "+++ATH" in one write is how NT4 RAS hangs up: escape, then the command
    w.write(b"ATDT555-1212\r")
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n")
    await asyncio.sleep(0.2)
    w.write(b"+++ATH\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n"), "+++ATH did not escape"
    assert b"OK" in await r.readuntil(b"OK\r\n"), "ATH after +++ was not obeyed"

    # an address dialled straight, with no phonebook entry: the T modifier
    # must not end up inside the hostname
    w.write(f"ATDT127.0.0.1:{port}\r".encode())
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n"), "direct address dial failed"
    await asyncio.sleep(0.2)
    w.write(b"+++ATH\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")
    assert b"OK" in await r.readuntil(b"OK\r\n")

    # telnet: mode must swallow the IAC handshake and answer it, so the guest
    # sees only the prompt -- and must double 0xFF on the way out
    seen = []

    async def fake_telnetd(tr, tw):
        tw.write(b"\xff\xfb\x01\xff\xfb\x03login: ")  # WILL ECHO, WILL SGA
        await tw.drain()
        while (d := await tr.read(100)):
            seen.append(d)

    td = await asyncio.start_server(fake_telnetd, "127.0.0.1", 0)
    book["5552323"] = f"telnet:127.0.0.1:{td.sockets[0].getsockname()[1]}"
    w.write(b"ATDT5552323\r")
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n")
    assert await r.readexactly(7) == b"login: ", "IAC negotiation reached the guest"
    w.write(b"\xff\x01")               # guest sends a literal 0xFF
    await w.drain()
    await asyncio.sleep(0.3)
    got = b"".join(seen)
    assert got.startswith(b"\xff\xfd\x01\xff\xfd\x03"), f"no DO ECHO / DO SGA: {got}"
    assert got.endswith(b"\xff\xff\x01"), f"0xFF was not doubled: {got}"
    await asyncio.sleep(0.2)
    w.write(b"+++ATH\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")
    assert b"OK" in await r.readuntil(b"OK\r\n")

    # dialling a line with nobody on it is BUSY, not NO CARRIER
    w.write(b"ATDT5559999\r")
    await w.drain()
    assert b"BUSY" in await r.readuntil(b"BUSY\r\n")

    # inbound, answered by hand -- NT4 RAS / TAPI issue ATA on RING
    cr, cw = await asyncio.open_connection("127.0.0.1", line)
    assert b"RING" in await r.readuntil(b"RING\r\n")

    # ...and while it rings, the line is engaged: the second caller is refused
    # by the kernel, so its modem reports BUSY instead of a phantom CONNECT
    try:
        await asyncio.open_connection("127.0.0.1", line)
        raise AssertionError("second caller was not given a busy line")
    except ConnectionRefusedError:
        pass

    w.write(b"ATA\r")
    await w.drain()
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n")
    cw.write(b"\xff\x03hello")  # a PPP-shaped frame, inbound this time
    await cw.drain()
    assert await r.readexactly(7) == b"\xff\x03hello"
    cw.close()
    assert b"NO CARRIER" in await r.readuntil(b"NO CARRIER\r\n")

    # inbound, auto-answered: the guest sets S0 and then says nothing at all
    w.write(b"ATS0=2\r")
    await w.drain()
    assert b"OK" in await r.readuntil(b"OK\r\n")
    cr, cw = await asyncio.open_connection("127.0.0.1", line)
    assert b"CONNECT" in await r.readuntil(b"CONNECT\r\n"), "S0 did not auto-answer"
    # switchboard: two lines in one process, an internal call between them
    tmp = tempfile.mkdtemp()
    ends = {}

    async def fake_qemu(nm):  # stands in for QEMU's listening serial socket
        async def cb(qr, qw):
            ends[nm] = (qr, qw)
        await asyncio.start_unix_server(cb, f"{tmp}/{nm}.sock")

    await fake_qemu("A")
    await fake_qemu("B")
    board, book2 = Switchboard(), {"5551111": "vm:B", "5552222": "vm:NOPE"}
    for nm in ("A", "B"):
        await serve(book2, [], connect=f"{tmp}/{nm}.sock", board=board, name=nm,
                    guard=0.05, ring=0.05)
    for _ in range(60):
        if len(board.lines) == 2 and len(ends) == 2:
            break
        await asyncio.sleep(0.05)
    assert len(board.lines) == 2, f"lines did not attach: {board.lines}"
    ar, aw = ends["A"]
    br, bw = ends["B"]

    aw.write(b"ATDT5551111\r")
    await aw.drain()
    assert b"RING" in await br.readuntil(b"RING\r\n"), "callee never rang"
    bw.write(b"ATA\r")
    await bw.drain()
    assert b"CONNECT" in await ar.readuntil(b"CONNECT\r\n")
    assert b"CONNECT" in await br.readuntil(b"CONNECT\r\n")
    both = bytes(range(256))  # the internal hop must be 8-bit clean too
    aw.write(both)
    await aw.drain()
    assert await br.readexactly(256) == both, "internal call is not 8-bit clean"

    # an unknown line is NO CARRIER; an engaged one is BUSY
    await asyncio.sleep(0.2)
    bw.write(b"+++")
    await bw.drain()
    assert b"OK" in await br.readuntil(b"OK\r\n")
    bw.write(b"ATDT5552222\r")
    await bw.drain()
    assert b"NO CARRIER" in await br.readuntil(b"NO CARRIER\r\n"), "unknown line"
    bw.write(b"ATDT5551111\r")   # line B calling... a line that is engaged (itself)
    await bw.drain()
    assert b"BUSY" in await br.readuntil(b"BUSY\r\n"), "engaged line was not BUSY"

    print("ok")


def _closed_port():
    """A port the OS just handed back, so nothing is listening on it."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _echo(r, w):
    while (data := await r.read(4096)):
        w.write(data)
        await w.drain()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    dte = ap.add_mutually_exclusive_group()
    dte.add_argument("--listen", help="unix socket path, or host:port, to listen on")
    dte.add_argument("--connect", help="unix socket path, or host:port, to dial into "
                                       "(PVE's -serial0 socket leaves QEMU listening)")
    ap.add_argument("--phonebook", help="86Box-format number->target map")
    ap.add_argument("--pppd", default="", help="command run for a 'ppp' target")
    ap.add_argument("--line", help="TCP port to accept incoming calls on")
    ap.add_argument("--vm", action="append", default=[], metavar="VMID[:PORT]",
                    help="switchboard line on a PVE VM's serial0 socket; repeatable. "
                         "PORT accepts calls from off-box (86Box on another host); "
                         "other lines reach it as the phonebook target vm:VMID")
    ap.add_argument("--debug", action="store_true", help="log the AT conversation")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO if a.debug else logging.WARNING,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    if a.selftest:
        return asyncio.run(selftest())
    if not (a.listen or a.connect or a.vm):
        ap.error("one of --listen, --connect or --vm is required")
    asyncio.run(_run(a))


async def _run(a):
    book, pppd = Phonebook(a.phonebook), shlex.split(a.pppd)
    if a.vm:
        board = Switchboard()
        for spec in a.vm:
            vmid, _, port = spec.partition(":")
            await serve(book, pppd, board=board, name=vmid, line=port or None,
                        connect=f"/var/run/qemu-server/{vmid}.serial0")
            log.info("line %s%s", vmid, f" answering on :{port}" if port else "")
    if a.listen or a.connect:
        await serve(book, pppd, listen=a.listen, connect=a.connect, line=a.line)
    await asyncio.Event().wait()


if __name__ == "__main__":
    main()
