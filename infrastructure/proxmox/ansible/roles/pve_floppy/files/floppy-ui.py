#!/usr/bin/env python3
"""Floppy drives for Proxmox VMs, which PVE itself cannot express.

There is no floppy in the PVE UI *or* the VM config schema, and PVE starts QEMU
with -nodefaults, so a retro guest has no A: at all unless one is smuggled in
through the `args` field. This is the UI for that.

Two facts shape the whole design:

  * `args` is root@pam-ONLY. The check in PVE::API2::Qemu is a literal
    `$authuser eq 'root@pam'`, and an API token's authuser is `root@pam!name`,
    so no token can ever set it. Hence: run on a node, shell out to `pvesh` as
    root. A network API client would need the root PASSWORD, which is worse.
  * `pvesh` proxies to whichever node owns the VM. So ONE instance on ONE node
    serves the whole cluster and keeps working when a VM migrates.

Changing `args` only takes effect on the next QEMU process, i.e. a real stop +
start; a guest-initiated reboot reuses the same process. Swapping the *medium*
of an existing drive is live, via the monitor. The UI reflects that split, and
deliberately has no stop/start buttons -- the PVE UI already has those.

LOGIN: no PAM code and no LDAP code here. The node already authenticates against
both -- realm `pam` for local accounts and realm `ad` for Samba AD over VERIFIED
LDAPS (roles/pve_auth) -- so this posts the credentials to PVE's own
/access/ticket and believes the answer. That also means it inherits the realm
list, the LDAPS certificate verification, and the account lockouts for free, and
holds no bind DN or password of its own.

Then AUTHORISATION, which is the half that matters: authenticating merely proves
you are someone in AD. Inserting a host file into a VM is a host-level action, so
a session additionally needs Sys.Modify on `/` in PVE's own ACL -- i.e. the same
`pve-admins-ad` group that already administers the cluster.
"""

import argparse
import base64
import concurrent.futures
import hmac
import html
import json
import os
import re
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Floppy media. .vfd is what the NT4 driver disks ship as; .ima/.flp/.dsk show
# up in retro archives. .iso is deliberately absent -- CD-ROMs PVE handles.
SUFFIXES = (".img", ".ima", ".vfd", ".flp", ".dsk")

# `args` is one shell-ish string and HMP `change` takes an unquoted path, so a
# filename with whitespace cannot be expressed in either without quoting rules
# that differ between the two. Such images are hidden rather than half-supported.
# ponytail: if a spaced filename ever matters, shlex.quote for args + rename for HMP.
FLOPPY_ARG = re.compile(r"-drive\s+if=floppy[^\s]*")

# pvedaemon, the API pveproxy itself proxies to. Used instead of `pvesh create
# /access/ticket` so the password never appears in a process argv, and instead of
# pveproxy:8006 so there is no TLS-to-self certificate dance. It is bound to
# loopback by PVE, so plain HTTP here does not put anything on the wire.
PVEDAEMON = "http://127.0.0.1:85/api2/json"

# What a logged-in user must additionally HAVE. Attaching a floppy points a VM at
# an arbitrary file on the host, so audit-level access is not enough.
REQUIRED_PRIV = "Sys.Modify"

# Sessions are signed with a key generated at startup: a restart logs everyone
# out, which for a homelab tool is a feature, not a limitation to engineer away.
SESSION_KEY = secrets.token_bytes(32)
SESSION_TTL = 8 * 3600


def pvesh(*args, check=True):
    """Run pvesh. Returns stdout. Raises RuntimeError with PVE's own message."""
    p = subprocess.run(
        ["pvesh", *args], capture_output=True, text=True, timeout=60
    )
    if check and p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip() or f"pvesh {args[1]} failed")
    return p.stdout


def pvesh_json(*args):
    return json.loads(pvesh(*args, "--output-format", "json"))


_REALMS = []


def realms():
    """Whatever PVE is configured with -- typically pam (local) and ad (LDAPS).

    Cached for the life of the process: this is on the LOGIN page, so without it
    every unauthenticated hit paid 1.9s for a `pvesh` to list something that
    changes when someone adds an auth domain -- i.e. never, and a restart picks
    it up.
    """
    if not _REALMS:
        _REALMS.extend(sorted(d["realm"] for d in pvesh_json("get", "/access/domains")))
    return _REALMS


def pve_authenticate(userid, password):
    """True if PVE accepts these credentials for this realm. No PAM/LDAP here."""
    data = urllib.parse.urlencode({"username": userid, "password": password}).encode()
    try:
        urllib.request.urlopen(f"{PVEDAEMON}/access/ticket", data=data, timeout=20).read()
        return True
    except urllib.error.HTTPError:
        return False  # 401 for a bad password, and for a disabled/expired account
    except urllib.error.URLError as e:
        # pvedaemon down is an outage, not a wrong password. Saying so avoids an
        # hour of retyping a password that was right all along.
        raise RuntimeError(f"PVE API unreachable: {e.reason}") from None


def pve_authorized(userid):
    """True if PVE's own ACL gives this user REQUIRED_PRIV on the whole tree."""
    perms = pvesh_json("get", "/access/permissions", "--userid", userid)
    return bool(perms.get("/", {}).get(REQUIRED_PRIV))


def _mac(msg):
    return hmac.new(SESSION_KEY, msg, "sha256").digest()


def session_new(userid):
    # The signature is HEX, not the raw digest: the parts are joined with '|'
    # and split back with rsplit, and 32 random bytes contain 0x7C ('|') about
    # 12% of the time -- which split the token inside its own signature and made
    # roughly one login in eight bounce straight back to the login page.
    msg = f"{userid}|{int(time.time()) + SESSION_TTL}".encode()
    return base64.urlsafe_b64encode(msg + b"|" + _mac(msg).hex().encode()).decode()


def session_user(cookie):
    """The userid a cookie proves, or None. Constant-time, expiry enforced."""
    try:
        raw = base64.urlsafe_b64decode(cookie.encode())
        msg, sig = raw.rsplit(b"|", 1)
        if not hmac.compare_digest(sig, _mac(msg).hex().encode()):
            return None
        userid, exp = msg.decode().rsplit("|", 1)
        return userid if int(exp) > time.time() else None
    except Exception:
        return None


def csrf_token(userid):
    return base64.urlsafe_b64encode(_mac(b"csrf|" + userid.encode())).decode()


def floppy_spec(path):
    return f"-drive if=floppy,format=raw,file={path}"


def args_with_floppy(args, path):
    """Add or replace the floppy drive in an existing `args` string."""
    spec = floppy_spec(path)
    if FLOPPY_ARG.search(args or ""):
        return FLOPPY_ARG.sub(spec, args, count=1).strip()
    return f"{args} {spec}".strip() if args else spec


def args_without_floppy(args):
    return " ".join(FLOPPY_ARG.sub("", args or "").split())


def floppy_in_args(args):
    """The image `args` will boot with, '' for a drive with no file, None for none."""
    m = FLOPPY_ARG.search(args or "")
    if not m:
        return None
    f = re.search(r"file=([^,\s]+)", m.group(0))
    return f.group(1) if f else ""


def read_conf(path):
    """Parse a PVE VM config off pmxcfs.

    Snapshots are appended as [name] sections after the live config, so stop at
    the first one. Split on the FIRST colon only -- an `args` value is full of
    them (file=/mnt/pve/...).
    """
    conf = {}
    try:
        f = open(path)
    except OSError:
        return conf
    with f:
        for line in f:
            if line.startswith("["):
                break
            key, sep, val = line.partition(":")
            if sep:
                conf[key.strip()] = val.strip()
    return conf


def inserted_medium(node, vmid):
    """What is in the drive RIGHT NOW, which is not what `args` says after a swap.

    The single most expensive thing this app does: 1.9s for a VM on this node,
    3.6s when pveproxy has to forward it to another one. Only ask for VMs that
    actually have a floppy drive, and only when the cache has expired.
    """
    try:
        out = pvesh("create", f"/nodes/{node}/qemu/{vmid}/monitor", "--command", "info block")
    except RuntimeError:
        return None
    m = re.search(r"^floppy0[^:]*:\s*(.*)$", out, re.M)
    if not m:
        return None
    val = m.group(1).strip()
    if val.startswith("[") or not val:
        return ""  # [not inserted]
    return val.split(" (")[0]


# A page load costs several pvesh round trips (a monitor query forwarded to
# another node is 3.6s on its own), and clicking around re-pays them every time.
# The TTL is deliberately longer than a human's click interval -- at 5s every
# click still missed. Staleness is bounded to someone else running `qm` by hand,
# because every action here clears the cache, so what you just did is never what
# you see stale.
CACHE_TTL = 30.0
_CACHE = {"at": 0.0, "rows": None}


def vms(fresh=False):
    """The VM table, read off pmxcfs instead of asked for one VM at a time.

    Every `pvesh` costs ~1.9s (Perl startup plus a cluster round trip), so the
    old shape -- one call for the list, then one per VM for its config, then one
    per running VM for its monitor -- made a four-guest page take ~16 seconds.
    /etc/pve is that same data replicated to every node, at file-read speed, so
    only the monitor round trips are left and those run in parallel.
    """
    if not fresh and _CACHE["rows"] and time.time() - _CACHE["at"] < CACHE_TTL:
        return _CACHE["rows"]
    ids = json.load(open("/etc/pve/.vmlist"))["ids"]
    out = []
    for vmid, meta in ids.items():
        if meta.get("type") != "qemu":
            continue
        conf = read_conf(f"/etc/pve/nodes/{meta['node']}/qemu-server/{vmid}.conf")
        args = conf.get("args", "")
        out.append({
            "vmid": int(vmid),
            "name": conf.get("name", ""),
            "node": meta["node"],
            "args": args,
            "configured": floppy_in_args(args),
        })
    # Everything remaining is a pvesh round trip, so overlap them: run status
    # alongside the monitors, and ask the monitor ONLY about VMs that have a
    # floppy drive -- "what is in the drive" is meaningless for the others, and
    # it was two thirds of the calls here.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        status = pool.submit(pvesh_json, "get", "/cluster/resources", "--type", "vm")
        media = {
            vm["vmid"]: pool.submit(inserted_medium, vm["node"], vm["vmid"])
            for vm in out
            if vm["configured"] is not None
        }
        running = {
            r["vmid"]: r.get("status") == "running"
            for r in status.result()
            if r.get("type") == "qemu"
        }
    for vm in out:
        vm["running"] = running.get(vm["vmid"], False)
        vm["inserted"] = media[vm["vmid"]].result() if vm["vmid"] in media else None
    rows = sorted(out, key=lambda v: v["vmid"])
    _CACHE.update(at=time.time(), rows=rows)
    return rows


def images(image_dir):
    return sorted(
        f
        for f in os.listdir(image_dir)
        if f.lower().endswith(SUFFIXES) and not re.search(r"\s", f)
    )


# Targets this UI is willing to write. It is an allowlist, not a blocklist,
# because a phonebook entry is a thing the modem ACTS ON: `ppp` and `ssh:` make
# it spawn a process, so a free-form target would be remote command execution
# wearing a phone number. Anything new must be added here deliberately.
PHONEBOOK_TARGET = re.compile(
    r"""^( ppp                                  # hand the line to pppd
         | vm:\d+                               # another line of the switchboard
         | ssh:[\w.@-]+(:\d+)?                  # ssh -tt to a host
         | (telnet:)?[\w.-]+:\d+                # raw TCP, or telnet with IAC handling
         )$""",
    re.VERBOSE,
)


def phonebook_read(path):
    try:
        return open(path).read()
    except OSError:
        return ""


def phonebook_check(text):
    """Return an error string, or None if every line is a comment or valid."""
    for n, line in enumerate(text.splitlines(), 1):
        body = line.split("#", 1)[0].split()
        if not body:
            continue
        if len(body) != 2:
            return f"line {n}: expected '<number> <target>'"
        if not body[0].isdigit():
            return f"line {n}: {body[0]!r} is not a phone number"
        if not PHONEBOOK_TARGET.match(body[1]):
            return f"line {n}: target {body[1]!r} is not one of ppp / vm:N / ssh:host / host:port / telnet:host:port"
    return None


def phonebook_write(path, text):
    """Write via a temp file in the same directory, so a failed write cannot
    leave the modem reading half a phonebook."""
    text = text.replace("\r\n", "\n")
    if not text.endswith("\n"):
        text += "\n"
    tmp = path + ".new"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


PAGE = """<!doctype html><meta charset=utf-8><title>PVE floppy</title>
<style>
 body{{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:60rem}}
 table{{border-collapse:collapse;width:100%}}
 td,th{{border-bottom:1px solid #ccc;padding:.5rem;text-align:left;vertical-align:top}}
 .msg{{padding:.6rem;background:#eef;border-left:3px solid #66c;margin-bottom:1rem}}
 .err{{background:#fee;border-color:#c66}}
 .note{{color:#666;font-size:.85em}}
 code{{background:#f4f4f4;padding:0 .2em}}
</style>
<h1>Floppy drives</h1>
<p class=note>{user} &mdash;
<form method=post action=/logout style=display:inline>
<input type=hidden name=csrf value="{csrf}"><button>log out</button></form></p>
<p class=note>PVE has no floppy in its UI or config schema; these live in
<code>args</code>. Attaching or detaching a drive takes effect on the next
<b>stop + start</b> (not a guest reboot). Inserting into an existing drive is live.</p>
{msg}
<table><tr><th>VM<th>drive in args<th>in the drive now<th>action</tr>
{rows}
</table>
<p class=note>Images: {image_dir} &mdash; names with spaces are hidden (see the source).</p>

<h1>Modem phonebook</h1>
<p class=note>{phonebook_path} &mdash; on pmxcfs, so every node sees it, and the
switchboard re-reads it on the next dial. No restart, and a call in progress
survives the edit.</p>
<form method=post action=/phonebook>
<input type=hidden name=csrf value="{csrf}">
<textarea name=text rows=10 style="width:100%;font-family:monospace">{phonebook}</textarea>
<br><button>Save phonebook</button>
</form>
"""

ROW = """<tr>
<td>{vmid} {name}<br><span class=note>{node}, {state}</span>
<td>{configured}
<td>{inserted}
<td><form method=post>
 <input type=hidden name=vmid value="{vmid}">
 <input type=hidden name=csrf value="{csrf}">
 <select name=image>{options}</select><br>
 {buttons}
</form>
</tr>
"""

LOGIN = """<!doctype html><meta charset=utf-8><title>PVE floppy</title>
<style>
 body{{font:14px/1.5 system-ui,sans-serif;margin:4rem auto;max-width:22rem}}
 input,select,button{{width:100%;padding:.4rem;margin:.2rem 0;box-sizing:border-box}}
 .msg{{padding:.6rem;background:#fee;border-left:3px solid #c66}}
 .note{{color:#666;font-size:.85em}}
</style>
<h1>Floppy drives</h1>
{msg}
<form method=post action=/login>
 <label>User<input name=user autofocus></label>
 <label>Password<input name=password type=password></label>
 <label>Realm<select name=realm>{realms}</select></label>
 <button>Log in</button>
</form>
<p class=note>Proxmox accounts. <code>pam</code> is local to the node,
<code>ad</code> is Samba AD over LDAPS. Needs {priv} on / in PVE.</p>
"""


def render_login(msg=""):
    opts = "".join(f"<option>{html.escape(r)}</option>" for r in realms())
    banner = f'<p class=msg>{html.escape(msg)}</p>' if msg else ""
    return LOGIN.format(msg=banner, realms=opts, priv=REQUIRED_PRIV)


def render(image_dir, user, msg="", err=False):
    opts = "".join(f"<option>{html.escape(i)}</option>" for i in images(image_dir))
    rows = []
    for vm in vms():
        if vm["configured"] is None:
            buttons = '<button name=action value=attach>Attach drive</button>'
            configured = "<span class=note>none</span>"
        else:
            buttons = (
                '<button name=action value=attach>Set in args</button> '
                '<button name=action value=detach>Detach drive</button>'
            )
            configured = html.escape(os.path.basename(vm["configured"]) or "(empty)")
        if vm["running"] and vm["inserted"] is not None:
            buttons += (
                ' <button name=action value=insert>Insert now</button>'
                ' <button name=action value=eject>Eject</button>'
            )
        if vm["inserted"] is None:
            inserted = "<span class=note>no drive</span>"
        else:
            inserted = html.escape(os.path.basename(vm["inserted"]) or "(empty)")
        rows.append(
            ROW.format(
                vmid=vm["vmid"],
                name=html.escape(vm["name"]),
                node=html.escape(vm["node"]),
                state="running" if vm["running"] else "stopped",
                configured=configured,
                inserted=inserted,
                options=opts,
                buttons=buttons,
                csrf=csrf_token(user),
            )
        )
    banner = (
        f'<p class="msg{" err" if err else ""}">{html.escape(msg)}</p>' if msg else ""
    )
    return PAGE.format(
        phonebook=html.escape(phonebook_read(Handler.phonebook)),
        phonebook_path=html.escape(Handler.phonebook),
        msg=banner,
        rows="".join(rows),
        image_dir=html.escape(image_dir),
        user=html.escape(user),
        csrf=csrf_token(user),
    )


def act(image_dir, action, vmid, image):
    """Perform one action. Every input is re-validated against live state.

    fresh=True on purpose: acting on a cached view of the cluster is exactly the
    case the cache must not cover, and the redirect afterwards has to show the
    result, not the state from before the click.
    """
    _CACHE["rows"] = None
    vm = next((v for v in vms(fresh=True) if str(v["vmid"]) == str(vmid)), None)
    if not vm:
        raise RuntimeError(f"no such VM: {vmid}")
    path = None
    if action in ("attach", "insert"):
        if image not in images(image_dir):  # no path traversal, no arbitrary host file
            raise RuntimeError(f"unknown image: {image}")
        path = os.path.join(image_dir, image)
    base = f"/nodes/{vm['node']}/qemu/{vm['vmid']}"

    if action == "attach":
        pvesh("set", f"{base}/config", "--args", args_with_floppy(vm["args"], path))
        return f"{vmid}: args now carry {image}. Stop and start the VM to get the drive."
    if action == "detach":
        rest = args_without_floppy(vm["args"])
        if rest:
            pvesh("set", f"{base}/config", "--args", rest)
        else:
            pvesh("set", f"{base}/config", "--delete", "args")
        return f"{vmid}: floppy removed from args. Takes effect on stop + start."
    if action == "insert":
        pvesh("create", f"{base}/monitor", "--command", f"change floppy0 {path}")
        return f"{vmid}: inserted {image}."
    if action == "eject":
        pvesh("create", f"{base}/monitor", "--command", "eject floppy0")
        return f"{vmid}: ejected."
    raise RuntimeError(f"unknown action: {action}")


class Handler(BaseHTTPRequestHandler):
    image_dir = "/mnt/pve/laptop/template/iso"
    secure = False  # set when serving TLS, so the cookie can demand it

    phonebook = "/etc/pve/retro-phonebook"

    def _send(self, code, body, headers=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, msg="", err=False):
        q = urllib.parse.urlencode({"msg": msg, **({"err": "1"} if err else {})})
        self._send(303, "", [("Location", f"/?{q}" if msg else "/")])

    def _user(self):
        cookie = SimpleCookie(self.headers.get("Cookie", "")).get("floppy")
        return session_user(cookie.value) if cookie else None

    def _form(self):
        n = int(self.headers.get("Content-Length", 0))
        return urllib.parse.parse_qs(self.rfile.read(n).decode())

    def do_GET(self):
        if self.path.split("?")[0] != "/":
            return self._send(404, "not found")
        user = self._user()
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            page = (
                render(self.image_dir, user, q.get("msg", [""])[0], "err" in q)
                if user
                else render_login(q.get("msg", [""])[0])
            )
        except Exception as e:  # a broken pvesh must show up, not 500 silently
            page = f"<h1>Floppy drives</h1><p class=msg>pvesh failed: {html.escape(str(e))}</p>"
        self._send(200, page)

    def do_POST(self):
        path = self.path.split("?")[0]
        form = self._form()

        if path == "/login":
            user = form.get("user", [""])[0].strip()
            # Everyone types the name they use everywhere else, `me@ad`, which
            # would become `me@ad@ad` and fail as "no such user". A sAMAccountName
            # cannot contain '@', so dropping a realm suffix is unambiguous.
            user = user.split("@")[0]
            realm = form.get("realm", [""])[0]
            if realm not in realms() or not user:
                return self._send(200, render_login("pick a valid realm"))
            userid = f"{user}@{realm}"
            try:
                ok = pve_authenticate(userid, form.get("password", [""])[0])
            except RuntimeError as e:
                return self._send(200, render_login(str(e)))
            if not ok:
                # One message for both cases on purpose: a distinct "no such
                # user" would enumerate the directory for anyone who can reach this.
                return self._send(200, render_login("login failed"))
            if not pve_authorized(userid):
                return self._send(200, render_login(f"{userid} lacks {REQUIRED_PRIV} on /"))
            cookie = (
                f"floppy={session_new(userid)}; Path=/; HttpOnly; SameSite=Strict"
                + ("; Secure" if self.secure else "")
            )
            return self._send(303, "", [("Location", "/"), ("Set-Cookie", cookie)])

        user = self._user()
        if not user:
            return self._send(200, render_login("session expired"))
        # SameSite=Strict already blocks cross-site posts in current browsers;
        # the token is what covers the ones that do not implement it.
        if not hmac.compare_digest(form.get("csrf", [""])[0], csrf_token(user)):
            return self._send(400, "bad csrf token")

        if path == "/phonebook":
            text = form.get("text", [""])[0]
            bad = phonebook_check(text)
            if bad:
                return self._redirect(bad, err=True)
            try:
                phonebook_write(self.phonebook, text)
            except OSError as e:
                return self._redirect(f"could not write phonebook: {e}", err=True)
            print(f"{user} saved phonebook", flush=True)
            return self._redirect("phonebook saved")

        if path == "/logout":
            return self._send(
                303, "", [("Location", "/"), ("Set-Cookie", "floppy=; Path=/; Max-Age=0")]
            )
        if path != "/":
            return self._send(404, "not found")

        action = form.get("action", [""])[0]
        vmid = form.get("vmid", [""])[0]
        try:
            msg = act(self.image_dir, action, vmid, form.get("image", [""])[0])
            _CACHE["rows"] = None  # the next render must show what just happened
            # Who did what to which VM belongs in the journal -- this app hands
            # out an action nothing else in PVE records.
            print(f"{user} {action} vm {vmid}: {msg}", flush=True)
            self._redirect(msg)
        except Exception as e:
            print(f"{user} {action} vm {vmid} FAILED: {e}", flush=True)
            self._redirect(str(e), err=True)

    def log_message(self, fmt, *a):
        pass  # journald already has the systemd unit's own noise


def selftest():
    # sessions: a valid one round-trips, a tampered or expired one does not
    s = session_new("me@ad")
    assert session_user(s) == "me@ad"
    # Repeated on purpose: a raw-digest signature only broke ~12% of the time,
    # so one round trip passed the test and still logged people out at random.
    for _ in range(300):
        assert session_user(session_new("me@ad")) == "me@ad", "flaky session token"
    assert session_user(s[:-4] + "AAAA") is None
    assert session_user("garbage") is None
    global SESSION_TTL
    SESSION_TTL, old = -1, SESSION_TTL
    assert session_user(session_new("me@ad")) is None, "expiry not enforced"
    SESSION_TTL = old
    assert csrf_token("me@ad") != csrf_token("you@ad")

    a = "-drive if=floppy,format=raw,file=/iso/a.img"
    assert floppy_in_args("") is None
    assert floppy_in_args(a) == "/iso/a.img"
    assert args_with_floppy("", "/iso/a.img") == a
    # replaces in place, does not duplicate, and leaves unrelated args alone
    mixed = f"-cpu foo {a} -boot order=a"
    swapped = args_with_floppy(mixed, "/iso/b.img")
    assert swapped == "-cpu foo -drive if=floppy,format=raw,file=/iso/b.img -boot order=a", swapped
    assert args_without_floppy(mixed) == "-cpu foo -boot order=a"
    assert args_without_floppy(a) == ""
    assert floppy_in_args("-drive if=floppy") == ""

    # phonebook: the allowlist is the security boundary, so test what it REFUSES
    assert phonebook_check("# just a comment\n5551212 ppp\n5551102 vm:102\n") is None
    assert phonebook_check("5552323 telnet:bbs.example.com:23\n") is None
    assert phonebook_check("5551000 ssh:root@10.0.0.1:22\n") is None
    assert phonebook_check("5551212 192.168.10.127:6060  # trailing comment\n") is None
    assert phonebook_check("5551212 exec:/bin/sh\n"), "exec: must be refused"
    assert phonebook_check("5551212 ppp; rm -rf /\n"), "shell metacharacters must be refused"
    assert phonebook_check("notanumber ppp\n"), "non-numeric number must be refused"
    assert phonebook_check("5551212\n"), "a target is required"

    # config parsing: args is full of colons, and snapshots follow the live config
    import tempfile
    conf = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
    conf.write(
        "name: retro-pdc\n"
        "args: -drive if=floppy,format=raw,file=/mnt/pve/laptop/template/iso/a.img\n"
        "cores: 1\n"
        "[snap1]\n"
        "args: -drive if=floppy,format=raw,file=/WRONG.img\n"
    )
    conf.close()
    c = read_conf(conf.name)
    assert c["name"] == "retro-pdc"
    assert c["args"].endswith("/iso/a.img"), c["args"]      # colons survived
    assert floppy_in_args(c["args"]).endswith("/iso/a.img")
    assert c["cores"] == "1"
    os.unlink(conf.name)
    assert read_conf("/nonexistent/vm.conf") == {}          # missing is empty, not fatal
    print("ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--image-dir", default=Handler.image_dir)
    ap.add_argument("--phonebook", default=Handler.phonebook,
                    help="modem phonebook; on pmxcfs so every node sees it")
    # The node's own ACME certificate (role pve_acme), the one pveproxy serves.
    ap.add_argument("--cert", default="/etc/pve/local/pveproxy-ssl.pem")
    ap.add_argument("--key", default="/etc/pve/local/pveproxy-ssl.key")
    ap.add_argument(
        "--insecure",
        action="store_true",
        help="serve plain HTTP. There is a password form on this app, so this "
        "puts credentials on the LAN in clear -- hence opt-in, not fallback.",
    )
    ap.add_argument("--selftest", action="store_true")
    o = ap.parse_args()
    if o.selftest:
        selftest()
        raise SystemExit(0)

    Handler.image_dir = o.image_dir
    Handler.phonebook = o.phonebook
    srv = ThreadingHTTPServer((o.listen, o.port), Handler)
    have_cert = os.path.exists(o.cert) and os.path.exists(o.key)
    if not have_cert and not o.insecure:
        # Fail closed: a login form on cleartext HTTP is worse than no service.
        raise SystemExit(f"no certificate at {o.cert} -- pass --insecure to serve anyway")
    if have_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(o.cert, o.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        Handler.secure = True
    print(f"listening on {'https' if Handler.secure else 'http'}://{o.listen}:{o.port}", flush=True)
    srv.serve_forever()
