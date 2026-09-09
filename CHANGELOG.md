# Changelog

What changed in this homelab, when, and why. Newest first.

**Conventions**
- One `##` section per date. No version numbers — services here are deployed
  continuously and independently, so there is nothing to tag.
- Lead with a one-line summary, then a table of what changed by area.
- **Incidents get their own subsection**, including anything self-inflicted. The
  post-mortem is the point: what broke, why, and whether it was latent.
- `Carried forward` lists known gaps left open on purpose, so they do not get
  silently forgotten.
- Agent-facing traps and procedures do **not** belong here — they go in
  `CLAUDE.md` under *Working rules* / *Environment constraints*.

---

## 2026-09-09

**Recorded the brownfield GitOps/IaC redesign before changing live infrastructure.**

| area | change |
|---|---|
| docs | Added `docs/homelab-gitops-redesign.md` as the durable record of control-plane boundaries, ingress and DNS consolidation, certificates, OCI recovery, CI placement, state recovery and phased adoption. It requires zero-change adoption before mutation and keeps PVE/OpenBao/Git recovery independent of k3s |
| OCI | Read-only discovery found the likely authoritative lost-root state in `oci-k8s-free-tier-tfstate/terraform.tfstate`: Terraform 1.15.8 state format 4, serial 249, covering the existing VM and public network. No state content or credential was committed; the bucket currently lacks versioning |
| secrets | Recorded that ESO 2.8.0, five ExternalSecrets and the scoped OpenBao Kubernetes-auth path already exist; the next gate is live recovery testing and migration of any remaining manual Secrets |
| Terraform | Recorded Gitea 1.27 State Registry as the preferred candidate for local roots after version and recovery testing; the OCI recovery root remains in OCI Object Storage to avoid a home-control-plane dependency loop |
| cleanup | Removed the retired NapCat tree, the Contour and Kanidm archive trees, and seven generated Terraform plan files before establishing the clean Git baseline; plans may embed complete state and remain globally ignored |
| CI | Added a review-first Gitea Actions runner bootstrap: official actions chart 0.1.1, pinned runner 2.3.0, one persistent instance-scoped Kubernetes runner with capacity four, plus an ESO reference to its registration token in OpenBao. The first deployment proved that rootlesskit is blocked by the node's AppArmor unprivileged-userns policy; because the chart requires privileged DinD in either mode, the reviewed fix uses regular DinD instead of weakening the host-wide policy |
| identity | Declared the Samba AD `gitea-admins` group with `panxiao81` as its initial member. Gitea already maps this OIDC group to site administrators; the local `gitea_admin` account remains as break-glass access |

`Carried forward`: re-verify OpenBao/ESO recovery and remaining Secret inventory;
configure a Git remote and off-site mirror; confirm the running Gitea version;
take an encrypted independent OCI state copy before enabling bucket versioning;
reconstruct the missing root to a zero-change plan; bootstrap Gitea Actions and Flux on a low-risk
service; then move Tunnel origins to Envoy one hostname at a time.

## 2026-08-15

**`retro-pdc` (NT4) has a floppy drive again — Proxmox does not offer one, so it
comes in through `args`.**

| area | change |
|---|---|
| proxmox | VM 102 gained `args: -drive if=floppy,format=raw,file=/mnt/pve/laptop/template/iso/retro-pdc-fda.img` and a blank FAT12 1.44 MB image to go with it. PVE exposes no floppy in the UI *or* the config schema, and it launches QEMU with `-nodefaults`, so before this the guest had no A: at all — `info block` listed only `drive-ide0`/`drive-ide2`. Verified after a power cycle: `floppy0 … retro-pdc-fda.img (raw)`. Swapping the medium works live (`eject floppy0` / `change floppy0 <path>` over `qm monitor`) — the block node id changed, so it really re-inserted; only an `args` edit needs the VM stopped and started |
| proxmox | **`roles/pve_floppy`** — a ~250-line stdlib-only web UI for the thing PVE has no UI for: attach/detach a floppy drive (edits `args`) and swap the medium live (`change floppy0` over the monitor). Its own play in `site.yml`, on **pve1 only** — the baseline play is `serial: 1`, which would have put three copies of the same UI on the LAN. One instance is enough because `pvesh` proxies to whichever node owns the VM, verified pve1→pve3 for `config`, `monitor` *and* the root-only `--args` write. It shells out as root instead of using an API token because it has to: PVE gates `args` on a literal `$authuser eq 'root@pam'` (`PVE::API2::Qemu`, the `# catches args, lock, etc.` branch) and a token's authuser is `root@pam!name`. No stop/start buttons — the PVE UI has those, and this app has no authentication |
| proxmox | The floppy UI got **authentication, without one line of PAM or LDAP code**: it posts the login form to PVE's own `/access/ticket`, so it accepts every realm the cluster has — `pam` for node-local accounts and `ad` for Samba AD over verified LDAPS (`pve_auth`) — and holds no bind DN, no bind password and no realm config of its own. It talks to **pvedaemon on `127.0.0.1:85`** rather than `pvesh create /access/ticket` so the password never appears in a process argv, and rather than pveproxy:8006 so there is no TLS-to-self dance. Authentication alone is not enough: a session also needs **`Sys.Modify` on `/`** in PVE's ACL (i.e. `pve-admins-ad`), because pointing a VM at an arbitrary host file is a host-level act, not a VM-level one. Sessions are HMAC-signed cookies (HttpOnly, SameSite=Strict, Secure), 8 h, with the signing key generated per process — a restart logs everyone out, deliberately. Serves TLS with the node's own ACME cert and **refuses to start without one** (`--insecure` to override): a login form on cleartext HTTP is worse than no service. Failed logins say only *"login failed"*, so the app cannot be used to enumerate AD |
| proxmox | The procedure is in `CLAUDE.md`. **Not** codified in `pve_vm`: VM 102 is not in `pve_vms` yet, and that gap is already tracked with the rest of the retro-pdc hardware pinning |

Two things learned power-cycling it. **NT4 ignores ACPI**: `qm shutdown 102 --timeout 60`
returned *"VM quit/powerdown failed - got timeout"* and the guest never moved, so it has to be
shut down from inside (`sendkey ctrl-esc`, `sendkey u`, `sendkey s`, `sendkey ret` over
`qm monitor`) and then `qm stop`ped once it shows *现在可以关掉电源*. And the shutdown dialog
defaults to **restart**, not power off — a guest restart keeps the same QEMU process, so the new
`args` would never have taken effect.

`Carried forward`: the guest side is unverified — NT4 came back to the Ctrl+Alt+Del
login screen and nothing here has its password. `A:` should hold a `README.TXT`
written to the image from the host.

The floppy UI **is deployed** on pve1 and serves TLS on 8088; the realm list it renders
comes back from the cluster (`ad`, `pam`, `pve`) and a wrong password gets *"login
failed"* through a real pvedaemon round trip. What is still unverified is everything
past a *successful* login — the VM table and the four actions have only ever run against
a stubbed `pvesh`, because no password for any realm exists in the session that built it.
No DNS record was needed: `pve1.ad.ddupan.top` already resolves, which is also why the
node's own ACME cert is the right one to serve.

### A modem emulator, so retro guests can dial an ISP

Retro guests expect dial-up, and there is no PSTN here. Three options were weighed before
writing anything:

| option | verdict |
|---|---|
| 86Box's built-in Hayes modem (since 4.2, and retrolab runs 6.0) | **Use it for 86Box guests.** Adapter `[COM] Standard Hayes-compliant Modem`, phonebook file maps a dialled number to `host:port`, non-zero listening port makes it answer. ⚠ Turn **Telnet emulation off** — PPP frames start `FF 03` and telnet IAC eats them. Its built-in internet mode (dial `0.0.0.0`) is **SLIP, not PPP**, so it needs the guest hacked into SLIP; not what a period PC did |
| `tcpser` for the QEMU guests | **Rejected.** Not packaged past bionic (source build), and its only socket DTE transport is **ip232**, which is not 8-bit transparent: `ip232_write` doubles every `0xFF`, `ip232_read` steals `FF 00`/`FF 01` for DTR, and the modem injects `FF <flags>` for DCD/RI. Read the source rather than assuming — `-serial tcp:` to it would corrupt every PPP frame and every ZMODEM block. Its `-p` port is the *phone line* side, not the serial side, so QEMU's telnet chardev cannot be pointed at it either |
| `roles/retro_modem/files/atmodem.py` | **Written.** ~420 lines, stdlib asyncio, no deps. Listens on a **unix socket** (PVE's `qm set -serial0 socket` plugs straight in) or TCP, so no socat + pty sandwich. `ATD` either opens a TCP connection or hands the raw line to **pppd** — an ISP terminal server, which is what the machines are actually dialling. `--line <port>` gives it a phone number: an inbound TCP connection rings the guest, which answers with `ATA` or automatically once it has set `S0`. That is the half **NT4's RAS needs to receive calls**, and it is also how one retro guest dials another |

Two non-obvious bits, both commented in place. Extended commands are `&X`/`%X`, so
searching for `D` to find the dial command fires on the `&D2` in every dialer's init
string and dials "2" — consume the prefix first. And unknown commands answer `OK` on
purpose: that is what makes an emulated modem work with dialers nobody has tested against.

`S0` auto-answer needed the DTE read to be interruptible: a guest that has set `S0` sends
*nothing* while waiting for a call, so the modem sits blocked reading the serial port and
could never decide to pick up on its own. The read now races an answer event.

`--selftest` is the acceptance test. It checks what ip232 gets wrong — dial through the
phonebook, round-trip all 256 byte values unchanged, escape with `+++` — then takes an
inbound call both ways, by `ATA` and by `S0`. It caught a real bug: when the far end
dropped, the outbound pump kept reading the serial port forever, so after `NO CARRIER` the
modem never returned to command mode and silently swallowed every later command. Both
directions now end the call.

**Busy signal, and the direction bug it flushed out.** A second caller now gets refused by
the kernel at `connect()`, because an engaged modem *closes its listening socket* until it
hangs up — a ringing line counts as engaged too. Accepting and then closing would have been
worse than nothing: the caller's modem would report `CONNECT` and immediately `NO CARRIER`,
which is a phantom call, not a busy tone. The dialling side maps `ConnectionRefusedError`
to **`BUSY`** and everything else to `NO CARRIER` (order matters — it subclasses `OSError`).

Writing that exposed a wrong assumption in the usage: **PVE's `-serial0 socket` leaves QEMU
listening**, so atmodem has to dial *into* the VM, not wait for it. Added `--connect`
alongside `--listen`; 86Box and plain TCP still want the listening side. Verified against a
stand-in listener — the guest end sees `OK` come back.

One process is one modem on one line, deliberately: that is what a modem is. An ISP's T1
into a rack of them is N processes on N ports. A single number in front of the rack is a
hunt group, i.e. a dispatcher, and that is **not** built.

**Existing AT libraries were checked and rejected**, so this does not get re-litigated:
almost everything on PyPI (`attila`, `python-gsmmodem`, `modem-cmd`, `esp_modem`) is the
**DTE** side — it *sends* AT to a real modem. `AT-Command-Emulator` is DCE but GSM
(`AT+CMGS`, SMS), so no dialling and no data mode. The one real match,
[`tcpatmodem`](https://github.com/stblassitude/tcpatmodem) (MIT, PyPI), is a DCE-side
interpreter — but its DTE side is **stdin/stdout only**, it cannot answer (`RING` appears
solely as an entry in its result-code table; no `bind`/`listen`/`accept` in the source),
and it was last touched in January 2019. Nor can its interpreter be lifted out on its own:
its dispatch table has no `&`, `%` or `\` entry and falls through to `ERROR`, with `a` and
`z` wired to `command_error` outright — so `AT&F` and `ATZ`, the first things every dialer
sends, both fail.

The deeper reason nothing is reusable: **commands and responses are different grammars.**
A command line is a run of concatenated commands with no separator (`AT&F&C1&D2S0=0X4E1V1`)
that cannot be tokenised without knowing the command set, and `D` swallows the rest of the
line; a response is line-oriented `\r\n<verb>\r\n` with `+CMD: <params>`. DTE libraries
parse the second, because a DTE never reads the first — it writes it. The one shared piece
is the `+CMD=<params>` parameter grammar, which is the part retro dial-up does not use. Adopting it would mean a dependency, a
socket↔stdio bridge, and a fork for the answering half, to replace a ~90-line parser. The
AT parsing is the commodity part; the socket DTE, the answering and the pppd hand-off are
not, and nothing off the shelf has them. Complete Hayes DCE implementations do exist —
DOSBox-X `serialmodem.cpp`, 86Box `net_modem.c`, tcpser `modem_core.c` — but all are C
welded into their host emulator. Read them if a dialer misbehaves.

**Verified end to end against a real `pppd`, not just the self-test.** A client `pppd`
dialled through atmodem into the `pppd` atmodem spawned for the `ppp` phonebook target —
i.e. the whole ISP chain, with no retro guest involved. From syslog:

```
send (ATDT5551212^M) / expect (CONNECT) / ATDT5551212^M^M / CONNECT / -- got it
Serial connection established.        Using interface ppp0 / ppp1
PAP peer authentication succeeded for retro   Remote message: Login ok
local IP address 10.62.0.1            remote IP address 10.62.0.2
```

Both ends came up (`ppp0` 10.62.0.1 ↔ `ppp1` 10.62.0.2), 11 frames and ~400 bytes each
way. That is LCP, PAP, IPCP and IPv6CP all negotiating across the emulated modem with
`asyncmap 0` in `/etc/ppp/options`, which is the strongest 8-bit-cleanliness proof
available — and it exercises the `ppp` target and the asyncio-subprocess pipe path, which
nothing had run before. Note `pppd notty` forks its own *charshunt* onto a pty internally
(`Connect: ppp0 <--> /dev/pts/6`); our pipes feed that fine. The test appended one line to
`/etc/ppp/pap-secrets` and restored the file from backup afterwards, verified identical.

**Then a real dialer found a real bug: `ATDT;`.** Driven against **VM 103 (Win98 SE)** on
pve3, whose `serial0: socket` atmodem attached to directly. Win98's Standard Modem opens
every call like this:

```
DTE> ATZ                    DCE< OK
DTE> ATE0V1&C1&D2S0=0       DCE< OK      <- the init string the design was betting on
DTE> ATM1X4                 DCE< OK      <- unknown commands, answered OK not ERROR
DTE> ATDT;                  DCE< OK      <- was NO CARRIER; that killed every call
DTE> ATDT5551212            DCE< CONNECT <- Win98 only sends digits after that OK
```

A trailing `;` means *"dial, then return to command state"*, and Windows TAPI **dials in
stages** — a bare `ATDT;` first, digits second. Answering `NO CARRIER` to the opener made
Win98 give up before it ever sent a number, which looked exactly like a phonebook miss and
was not one. `dial()` now accumulates staged digits and answers `OK`; the self-test replays
the whole Win98 sequence verbatim so it cannot regress.

The two design calls that looked arbitrary are the two that carried it: consuming `&`/`%`
prefixes before looking for `D` (or `&D2` dials "2"), and answering `OK` to unknown
commands (or `M1X4` aborts the dial). tcpatmodem would have failed on line 2.

**Result: Windows 98 is on the network over an emulated modem.** ISP was `pppd` on the
laptop, reached over the LAN from pve3, so nothing was installed on the node:

```
call from ('192.168.10.9', 57456)
ppp0  UNKNOWN  10.62.0.1 peer 10.62.0.2/32
64 bytes from 10.62.0.2: icmp_seq=1 ttl=128 time=12.8 ms   (4/4, ttl=128 = Windows)
```

Also learned: Win98 does **not** drive PVE's USB tablet, so QMP `input-send-event` abs
clicks are accepted by QEMU and ignored by the guest — until the guest installs USB HID.
And Win98's own dialling properties prepend the location's outside-line digit and country
code (`0 5551212`, canonical `86-5551212`), which `digits()` cannot match; untick
**使用区号与拨号属性** in the connection's properties.

**And then Win98 dialled NT4.** Two atmodems on pve3 — one on VM 103's `serial0` with the
phonebook, one on VM 102's `serial0` with `--line 6102` — turn `5551102` into a call from
the Win98 guest to `retro-pdc`'s Remote Access Server (RETRO001, 1 port, 正在运行):

```
WIN98   DTE> ATDT;          DCE< OK
        DTE> ATDT5551102    DCE< CONNECT
NT4     DTE> ATH / AT / ATE0V1 / AT / ATS0=0     <- RAS initialising the port
        DCE< RING                                 <- our modem rings it
        DTE> ATA                                  <- RAS answers by hand
        DCE< CONNECT
```

That validates the whole answering half (`--line` → `RING` → `ATA`) against a real NT 4.0
RAS, and settles a design guess: **RAS sets `S0=0` and answers manually on `RING`**, so the
`ATA` path is the one that carries, and `S0` auto-answer is there for DOS-era software.
RAS's init sequence is a *third* dialer handled without changes. Everything above the
modem — PPP and NT4 domain authentication against RETRO — was left to the operator, who
was at the keyboard by then.

**RAS then found the second real bug: `+++ATH` as one write.** NT4 hangs up by sending the
escape and the command glued together, and `_dte_to_peer` matched only a bare `b"+++"` — so
the whole string was forwarded to the far end as data and the line could never be dropped.
A bare `+++` still waits out its trailing guard; `+++` followed by a command is
unambiguous, so it escapes at once and the remainder goes to the command reader through a
small pushback buffer. In the logs this showed up as `+++ATH` → `ERROR` (that part is
correct — in *command* mode real modems error too; the bug was the data-mode path).

Reading the rest of that log is a lesson in not blaming the layer you just wrote. RAS
answered three calls cleanly, each running 45–75 s before **RAS** hung up — a failure above
the modem (PPP/auth), matching 端口状态 showing 线路未连接 with zero bytes counted. And the
eight unanswered `RING`s were Win98 hanging up and **redialling in the same second**
(`ATH` … `ATDT5551102` both at 22:02:55), before RAS had re-armed its port — the period-
accurate equivalent of redialling before the far end's modem has reset. RAS re-initialises
with `AT`/`ATZ`/`ATE0V1`/`ATS0=0` when it recovers.

**Dialling an address directly was broken, and only asking about it found it.** `D` takes
an optional **T**one/**P**ulse modifier, which was never stripped — so `ATDT192.168.10.1:23`
tried to resolve the host `T192.168.10.1` and returned `NO CARRIER`. The phonebook path hid
it completely, because lookups go through `digits()`. Strip exactly one modifier, never
`lstrip()`, or `ATDTtelnet.example.com` loses its `t`. Now covered by the self-test.

**`telnet:` targets.** A raw TCP pipe is wrong for a real telnetd: dialling `192.168.10.1:23`
delivered `\xff\xfb\x01\xff\xfb\x03login: ` to the guest — `IAC WILL ECHO, IAC WILL SGA`
rendered as `ÿû☺ÿû♥` before the prompt — and an un-doubled `0xFF` corrupts any 8-bit
transfer. A `telnet:host[:port]` phonebook target now wraps the peer in a ~45-line telnet
client: it swallows IAC sequences, answers `DO ECHO`/`DO SGA` and refuses everything else,
un-escapes `IAC IAC`, and doubles `0xFF` outbound. Same dial through it now yields exactly
`\r\nCONNECT\r\nlogin: `.

It is **opt-in per entry** for the same reason 86Box's telnet toggle has to be turned off:
enabling IAC handling on the PPP or guest-to-guest numbers would corrupt them, since there
`0xFF` is data — `FF 03` starts every PPP frame.

**Redesigned into a switchboard, which came out smaller than what it replaced.** Dialling
a VM cannot be another target type: the answering guest needs a *modem* to hear `RING` and
reply `ATA`, so wiring a caller straight to its serial socket hands RAS raw bytes and it
never picks up. Only a process holding both ends can ring one on behalf of the other. So
one process now owns N lines (`--vm 102:6102 --vm 103`), and `vm:102` is an internal call:

| before, 2 guests | after |
|---|---|
| 2 processes, 1 TCP port, 2 logs | 1 process, 1 log |
| a `--line` port allocated per VM | internal routing by vmid |
| busy = open/close a listener | busy = does that line have a call |
| hunt group impossible | falls out of the line table |

The internal hop is a `socket.socketpair()`, so every path below it — the pump, 8-bit
cleanliness, `+++`, `NO CARRIER` — is the same validated code that carries an external
call. Per-line TCP ports stay, because **86Box lives on retrolab**, a different host, and
has to reach a line over the network. Lines also reattach on their own now: a guest reboot
takes the chardev peer with it, and a switchboard needing a restart after every VM reboot
is not a service.

**The phonebook is the API — there isn't one.** It hot-reloads on mtime change, so editing
a number no longer restarts the modem or drops a live call. That single change removes any
need for a daemon protocol: the file lives on **pmxcfs** (`/etc/pve/retro-phonebook`), so
`pve_floppy` running on **pve1** edits exactly what the switchboard on **pve3** reads, with
no IPC, no API and no second service. The UI gained a phonebook textarea rather than
becoming a new app, so it inherits the PVE ticket auth, the AD realm, TLS on the node cert
and the `Sys.Modify` gate that were already there. (pmxcfs mtime has 1-second granularity —
two edits inside one second would be missed. Irrelevant for human or UI edits.)

Targets are an **allowlist, not a blocklist**, and that is the security boundary: a
phonebook entry is something the modem *acts on* — `ppp` and `ssh:` make it spawn a process
— so a free-form target would be remote command execution wearing a phone number. `exec:`
was deliberately never added for that reason, and the UI's self-test asserts what it
*refuses* (`exec:`, shell metacharacters, non-numeric numbers), not just what it accepts.

Also added: `ssh:user@host[:port]` (the same subprocess shape as `ppp`, so nearly free).

### The floppy UI was taking ~22 seconds a page; now 4 cold, 0 warm

Measured before changing anything, which is the whole story: **every `pvesh` costs ~1.9 s**
(Perl startup plus a cluster round trip), and a monitor query *forwarded to another node* is
**3.6 s**. The page made one call for the VM list, one per VM for its config, and one per
running VM for its monitor — 1 + 4 + 4 calls for four guests.

| fix | why it works |
|---|---|
| Read configs off **pmxcfs** (`/etc/pve/.vmlist`, `/etc/pve/nodes/<node>/qemu-server/<vmid>.conf`) | Exactly the data `pvesh get .../config` returns, already replicated to every node, at file-read speed. Removed 5 of the 9 calls |
| Ask the monitor **only about VMs that have a floppy** | "What is in the drive" is meaningless for a VM with no drive. Two thirds of the monitor calls were asking anyway |
| Run the survivors **in parallel** | `ThreadingHTTPServer` already gives each request a thread; fanning out inside it makes N round trips cost about one |
| **Cache**, TTL 30 s, cleared by every action | At the 5 s I first wrote, every click still missed — the TTL has to be longer than a human's click interval to ever be warm |

Result: 14.4 s just for the list+config calls became a file read, and the page went
**~22 s → 4.04 s cold, 0.000 s warm**, same data. The remaining 4 s is one forwarded
monitor call and is the floor for `pvesh`; beating it needs the API over HTTP with a
retained ticket, i.e. server-side session state this app deliberately does not have (its
sessions are stateless signed cookies). Not worth it for a page that is now instant in use.

Config parsing has its own test: snapshots are appended as `[name]` sections after the live
config so parsing must stop at the first one, and the split is on the **first** colon only
because an `args` value is full of them.

The login page was its own 1.9 s, before any of that: `realms()` ran a `pvesh` on every
unauthenticated hit to list something that changes when an auth domain is added, i.e.
never. Cached for the process lifetime — 2.01 s cold, then **0.034 s**.

Deployed with `--tags floppy`; a second run reports `changed=0`.

#### Incident — one login in eight was silently rejected (latent since the app was written)

The deploy failed on `pve_floppy`'s own self-check, which then passed on a rerun. Chasing
the flake rather than re-running found a real bug in session cookies, not in the test:

```python
return base64.urlsafe_b64encode(msg + b"|" + _mac(msg)).decode()   # sign
msg, sig = raw.rsplit(b"|", 1)                                     # verify
```

The signature is the **raw 32-byte HMAC digest**, and 32 random bytes contain `0x7C` — the
byte for `|` — about **12 %** of the time (`1 - (255/256)**32`). When they did, `rsplit`
split the token *inside its own signature*, `compare_digest` failed, and the user was
bounced back to the login page. Random, unreproducible, and it had been there since the app
was written — never noticed because, as recorded above, nothing past a *successful* login
had ever been exercised.

Fix: sign with `_mac(msg).hex()`, which cannot contain the separator. The regression test
does 300 round trips rather than one, because a single round trip passed ~88 % of the time
and that is exactly how this survived having a test at all. Verified 20/20 self-test runs on
the node after deploying, and the service is confirmed running the new binary — the failed
run had installed the file but died before its restart handler, leaving the old code live.

Not yet done: DTR-drop hangup, S-registers beyond `S0`, and the `retro_modem` Ansible role
— the switchboard runs from `/tmp` on pve3 and the `pve_floppy` change is not deployed.

### retronet's WINS now points at the NT4 PDC, not the production DC

`retro-pdc` came up on its static **10.61.0.5** with the WINS service installed, so
retronet's DHCP `wins-server` moved from `192.168.10.5` (the Samba DC) to it —
`vyos_router` defaults, applied and saved, second run `changed=0`. Verified end to end
rather than assumed: TCP/42 and 139 open, `nmblookup -A` shows the box holding
`RETRO<1b>` / `RETRO<1d>` / `..__MSBROWSE__.` (it is the domain master browser), a
recursive WINS query through it resolves `RETRO01<00>` → 10.61.0.5, and kea's generated
config carries `netbios-name-servers: 10.61.0.5` for the subnet. That removes retronet's
last dependency on the production DC. Note the NetBIOS domain is **`RETRO`**, host
**`RETRO01`** — not `RETRONET`, which is only the VNet/shared-network name.

⚠ **`option wins-server` is a multi-value node**, so the role's `set` line *added* a second
server rather than replacing the first — both were live, and both were written to
`config.boot` by the play's `save: true`. Removed with an explicit `delete`. The role is
set-lines-only by design and can never remove a stale value; changing any multi node needs
a one-off delete against the live box. Trap recorded in `CLAUDE.md`.

---

## 2026-07-28

**The repo got git history for the first time; a stage-1 lint gate; and
`auth.ddupan.top` now resolves on the LAN instead of via Cloudflare.**

| area | change |
|---|---|
| repo | First commit ever — 490 files, ~11.8 MB. Root `.gitignore` added; ~13 GB of ISOs, WinPE images, HF model blobs, `node_modules` and vendored netboot menus excluded, along with nine secret-bearing files. Later the same day `blocky/logs/` joined them — Blocky writes one query log per day, the first had already been committed, so it is ignored **and** `git rm --cached`d. It stays in the history of `fde9ff2`: every DNS query the LAN made that day, no credentials |
| ci | Stage-1 lint: `yamllint`, `ansible-lint`, `terraform fmt`/`validate`. Config tuned against a real run — 293 YAML errors down to 0, 300 Ansible findings down to 34 |
| proxmox | Added `ansible/requirements.yml`. It had never existed, while the other two Ansible projects declared theirs — so `ansible.netcommon`, `vyos.vyos`, `ansible.posix` and `community.general` were undeclared and a fresh checkout could not reproduce the environment |
| cert-manager | `certificate-auth-ddupan.yaml` — LE cert for `auth.ddupan.top`. The `*.ad.ddupan.top` wildcard cannot cover it: different zone, one label shallower |
| envoy-gateway | Second HTTPS listener `https-auth`, SNI-selected. The existing `*.ad.ddupan.top` listener is untouched |
| authelia | `httproute.yaml` routes `auth.ddupan.top` to the `authelia` Service |
| k3s | CoreDNS answers `auth.ddupan.top` with the gateway (192.168.10.127) and suppresses AAAA |
| gitea | Actions enabled (`ENABLED=true`, `DEFAULT_ACTIONS_URL=github`). No runner deployed yet, so nothing executes |
| victoriametrics | 25 whitespace fixes, each verified to parse to an identical document. Two alert-rule files were deliberately **not** fixed — their trailing spaces sit inside `\|` literal block scalars and are part of the alert text |
| docs | `CHANGELOG.md` (this file) and `docs/cicd.md`, the CI/CD design. `docs/superpowers/` retired — its only work, the 2026-04-18 CloudNativePG migration, shipped and has been healthy 101 days |
| secrets | All four secret-bearing configs returned to git. **cloudflared**: the credentials Secret and `config.yml` ConfigMap were *dead* — deleted rather than externalised (see below); the tunnel token moved to a gitignored `secret.yaml` with a committed template. **gitea**: DB password moved to a `gitea-db` Secret, injected via `gitea.additionalConfigFromEnvs` as `GITEA__DATABASE__PASSWD`. **litellm-gateway**: compose now interpolates `${POSTGRES_PASSWORD}` from its already-gitignored `.env`. **authelia**: all seven pieces of secret material moved into Secrets via `secret.existingSecret` + `secret.additionalSecrets`, which also took the OIDC signing key out of a plaintext ConfigMap (see below) |
| external-secrets | **ESO 2.8.0 deployed**, pulling all four Secrets from OpenBao. The operator authenticates with its own ServiceAccount JWT via bao's Kubernetes auth backend, so no credential is stored in the cluster. Policy scoped to `kv/k8s/*` read-only — narrower than the human `admin` policy |
| openbao | Kubernetes auth backend **enabled and configured for the first time** — it had never existed. Two stale defaults fixed: `openbao_k8s_host` pointed at `192.168.10.10` (nothing listens there), and `openbao_addr` used `127.0.0.1`, which now fails TLS because bao's Let's Encrypt cert has a DNS SAN only |
| terraform | **All four roots migrated from local state to SeaweedFS S3** (`tfstate` bucket), with native `use_lockfile` locking. Reached over a new LAN route (`s3.ad.ddupan.top`) rather than `obj.ddupan.top`, so state does not depend on the WAN |
| seaweedfs | S3 identities moved out of `values.yaml` into OpenBao via ESO, plus a least-privilege `terraform` identity scoped to the state bucket |
| blocky | **Staged, not deployed.** LAN resolver + ad-blocker + split-horizon DNS, as a compose stack on the laptop. Fills a real gap: there is nowhere today to put a LAN record for a `ddupan.top` name — the DC is authoritative only for `ad.ddupan.top`, and the NEC IX has no static-host feature |
| gitea | LAN route added: cert for `git.ddupan.top`, a third gateway listener (`https-git`) and an HTTPRoute. Serves HTTP 200 in 32ms, so `git push` no longer has to leave the LAN. **DNS not yet switched** — nothing resolves it locally until Blocky or a DC zone lands |
| smtp-relay | **DKIM signing enabled for `ddupan.top`** — mail relayed via M365 was landing in Junk. The signing config existed but had never been switched on (`Enabled: False`, `Status: CnameMissing`), so outbound mail carried only the tenant's `*.onmicrosoft.com` signature, which does not align with `ddupan.top`. No DNS change was needed |
| tailscale | **The PVE SDN subnets are now advertised** — the laptop, the tailnet's only subnet router, offered `192.168.10.0/24` and nothing else, so `10.60.0.0/24` (labnet) and `10.61.0.0/24` (retronet) were unreachable from the tailnet even though the laptop has had OSPF routes to both all along. Recorded in `tailscale/subnet-routes.sh` rather than left as shell history, since the whole failure mode is forgetting the step. retronet is included deliberately: quarantining it from the LAN is the point, quarantining it from the tailnet just forces a second VPN. **Both still need approving in the admin console** |
| retrolab | **86Box mouse capture fixed over RDP.** xorgxrdp's pointer declares relative axes (`REL_X`/`REL_Y`, range `-1..-1`) but posts absolute screen coordinates through them — `xf86PostMotionEvent(dev, TRUE, …)`. 86Box's XInput2 backend trusts the declared mode and fed those absolutes in as movement deltas, pinning the emulated pointer in a corner the moment you clicked to capture. 86Box only ever exempts pointers *by device name* (`TigerVNC pointer`, `Virtual core XTEST pointer`), so `retro_desktop` now renames the xrdp pointer to `TigerVNC pointer` in `/etc/X11/xrdp/xorg.conf`. Also gave the role's channel-read task `check_mode: false`, without which every `--check` run asserted that audio was broken |

The hostname deliberately did not change. Issuer, redirect URIs and cookie
domain all remain `auth.ddupan.top`, so no OIDC client needed re-registering —
only the network path moved. The public route (Cloudflare → tunnel →
`cloudflared` → authelia) still works and terminates at the same Service.

### Incident — retrolab logins came up with no window manager (self-inflicted)

No title bars, no Applications menu, so no way to log out — reported as "I can't
logout now", and it came back after the move to pve3 because the cause is
persistent, not transient.

`xfce4-session` restores exactly the client list in
`~/.cache/sessions/xfce4-session-retrolab:10`, and that list had **Count=4:
xfsettingsd, xfce4-panel, Thunar, xfdesktop** — no `xfwm4`. Once the WM is
missing from a saved session, every later login is WM-less too.

Self-inflicted, and the recovery caused the relapse: xfwm4 had died earlier
(cause unknown, `.xsession-errors` shows an older `Another compositing manager
is running on screen 0`), and it was restarted over SSH with `xfwm4 --replace`.
That process has no `SESSION_MANAGER` in its environment — it logs "Failed to
connect to session manager" — so the next session save did not record it.

Fixed on the host: restarted the WM, set
`xfconf-query -c xfce4-session -p /general/SaveOnExit -n -t bool -s false`, and
deleted the stale session file. Left as a documented trap in
`roles/retro_desktop/tasks/main.yml` rather than a task — see the comment there
for why automating it costs more than it saves. The distro's failsafe session
does not help: xrdp never offers the greeter that selects it.

### retrolab moved from pve1 to pve3 — 86Box was CPU-starved

86Box emulation stuttered and the emulated Sound Blaster glitched. pve1 is an
**i3-6100U, 2 cores / 4 threads at 2.3 GHz**, and it also carries `vyos-rtr`;
it was sitting at load 2.0 with 50% CPU. 86Box's recompiler is effectively
single-threaded, so it wanted clock, not cores.

pve3 was the target rather than pve2 for a storage reason, not a CPU one — both
are **Ryzen 5 PRO 2400GE (4c/8t, 3.2 GHz)** and both idle, but LINSTOR holds an
**UpToDate replica on pve3 and only a Diskless one on pve2**, so on pve2 every
block would have crossed the network to another node's disk.

`cpu: host` was already set, which is most of the performance win but also
forced the migration to be **offline**: pve1 is Intel, pve2/pve3 are AMD, and a
live migration would have handed the running kernel a different feature set.
Shutdown, `qm migrate` (2 seconds — nothing to copy, shared DRBD), start. The
guest now reports the Ryzen. vm:101 is not an HA resource, so nothing else
needed rearranging.

Verified after the move, because this was the first time either SDN VNet had to
leave a node: the DHCP reservation still resolves (`10.60.0.10`, VLAN 100), and
`br-retro` reaches the VyOS gateway `10.61.0.1` on VLAN 110 — both now crossing
the physical 1G LAN to reach vyos on pve1 instead of staying inside one host.
`xrdp` and the laptop's `/mnt/iso` NFS mount came back on their own.

Win98 took a hard power-off (ScanDisk on next boot): the guest OS ignored ACPI
shutdown until its timeout, and the desktop session could not be driven to shut
the emulator down cleanly first.

### 86Box's Win98 guest could not DHCP — the emulated cable was unplugged

Symptom: Win98 on retronet got only an APIPA address, `winipcfg` renew failed
instantly with "DHCP 服务器不存在". Everything downstream of the guest was
healthy and measured that way: `br-retro` up with `enp6s19` **and** `tap0`
enslaved and forwarding, an address temporarily added to `br-retro` pinged the
VyOS gateway `10.61.0.1`, and kea was listening on `10.61.0.1:67` with the
`RETRONET` pool configured.

The tell was `ip -s link show tap0`: **RX 0 packets, ever** — TX counted the
frames the bridge flooded *toward* the guest, but 86Box had never written a
single frame *from* it. Not a fabric problem at all.

Cause: `net_01_link = 2` in `~/86Box VMs/98/86box.cfg`. In 86Box
`NET_LINK_DOWN = (1 << 1)`, so the value means the NIC's link is **down** —
86Box's own "unplug the cable" toggle, reachable by clicking the network icon
in its status bar. The default is `504` (every speed/duplex bit set); deleting
the line restores it. The guest driver was fine throughout: it read its MAC
(`00:E0:4C:CB:7A:58`) off the emulated PROM and bound TCP/IP normally.

Fixed by removing the line and restarting the emulator. Win98 now holds
**10.61.0.107** from the `RETRONET` pool, first lease that segment has ever
handed out.

Consequence, and the reason the VM does not boot unattended: the NIC's boot ROM
is enabled (`bios = 1` under `[Realtek RTL8029AS #1]`), and with the link up
Etherboot 5.4.4 now runs a DHCP loop at every boot instead of failing
instantly. It never accepts kea's reply — the reply is on the wire, addressed
to the card, and Etherboot still prints `No IP address` — so it retries
indefinitely and the machine never reaches the hard disk. Press **Q** at
`Boot from (N)etwork or (Q)uit?` to skip it; set `bios = 0` if PXE on retronet
is not wanted. Left as-is: enabling that ROM looks deliberate.

### Incident — retrolab's desktop stranded again (needrestart, second occurrence)

Same failure as 2026-07-25, different trigger. **unattended-upgrades** upgraded
`libc6` at 06:28:37, and needrestart restarted `xrdp-sesman` at 06:28:55.
sesman came back with an empty session table and could no longer reattach the
running `:10` display, so every reconnect started a *new* one — and
`xfce4-session` refuses to run twice for the same user, so each died in about a
second (`Window manager (pid 102992, display 11) exited quickly (1 secs)`). The
desktop and its 86Box Win98 VM kept running, just permanently unreachable.

The 2026-07-25 fix was `NEEDRESTART_MODE: l` in `retrolab.yml`, which only ever
covered *our* playbook runs. Ubuntu's automatic upgrades were never in scope,
which is why the same thing happened again eight hours before anyone noticed.

Recovered by killing `:10` outright (86Box included — no way to save it, the
session could not be reached to shut it down). Fixed properly with
`/etc/needrestart/conf.d/50-xrdp.conf` pinning `qr(^xrdp)` to `0`, deployed by
the `retro_desktop` role. This is the mechanism needrestart already uses for
`gdm`, `sddm` and `xdm` — xrdp-sesman is the same class of service and simply
was not on the list. Trade accepted: sesman runs against the old libc until the
host reboots.

Watch for this on any other host that grows a long-lived xrdp session.

### Incident — Gitea down ~12 minutes (self-inflicted trigger, latent cause)

Enabling Actions required a `helm upgrade`, and the chart's `strategy: Recreate`
kills the old pod before starting the new one. The new pod never came up.

The cause was **not** the config change. `configure-gitea` is an **init**
container running `gitea admin auth update-oauth`, which *fetches*
`autoDiscoverUrl` before Gitea will start. That URL was unreachable, so the init
container exited non-zero and the pod crash-looped. Any restart — node reboot,
eviction, chart bump — would have done the same. Rolling back would not have
helped, because the rollback also restarts the pod.

Restored by temporarily commenting out the `oauth:` block (the auth source
stays in Gitea's DB; commenting only stops the init-time sync), then permanently
by moving `auth.ddupan.top` onto the LAN.

### Incident — a dead VPN tunnel masquerading as a bad ISP

`openvpn-client@naist.service` reported `active running` and its interface was
`UP`, but the tunnel was dead — 100% loss to its own gateway, 29,156 dropped TX
packets. Its **58 split-tunnel routes stayed installed**, blackholing Cloudflare
(`104.21/16`, `172.67/16`), Fastly (`151.101/16`), Microsoft `13.107.x`, AWS
CloudFront and Akamai. `github.com` is not in that route set, which is why it
kept working and made the failure look like selective CDN blocking.

This was the real cause of the Gitea outage above, of `pypi.org` being
unreachable, and — because pods use the host routing table — of the same
blackhole applying cluster-wide. `pve1` was unaffected throughout, having no
`tun0`. Fixed by restarting the service.

### DKIM: the CNAMEs were right all along

The published CNAMEs matched `Selector1CNAME`/`Selector2CNAME` exactly, yet
`ddupan1.d-v1.dkim.mail.microsoft` was **NXDOMAIN** — which reads as a wrong
tenant label and sends you hunting for the "real" value. It is not.
**Microsoft creates the tenant host only when signing is enabled**, so the
target cannot resolve before `Set-DkimSigningConfig -Enabled $true`. The
NXDOMAIN was the expected pre-enable state, not a fault. After enabling, the
zone answered `NOERROR` and both selectors served 2048-bit keys immediately.

Corollary: `Status: CnameMissing` on a config that has never been enabled does
not mean your DNS is wrong. Enable it and re-check before touching DNS.

**Verified end-to-end**, headers of a test message received at an external
Outlook.com account: `dkim=pass (signature was verified) header.d=ddupan.top`,
`spf=pass`, `dmarc=pass`, `compauth=pass reason=100`.

**It still landed in Junk** — `X-MS-Exchange-Organization-SCL: 5`
(`X-Message-Delivery` decodes to `SCL=6`), `dest:J`, `RF:JunkEmail`. Note the
split: the tenant-side outbound stamp was `SCL:1`, so the score came from the
*receiving consumer* filter. Authentication is a precondition for good
placement, not a guarantee of it — the remainder is reputation (`ddupan.top`
has no sending history and relays via a shared M365 outbound pool,
`52.101.228.88`) plus content (the test messages were one-line bodies with
"test" in the subject, no charset, no `MIME-Version` — a worst case for
scoring). Nothing further to configure; it needs real traffic, time, and
"not junk" marks.

### Discovered — IPv6 broken host-wide on the laptop (not fixed)

`Connect-ExchangeOnline -Device` hung with no output. The cause was not the
module: **`br0` has no global IPv6 address**, because
`net.ipv6.conf.all.forwarding=1` (needed for libvirt/k3s) makes the kernel
default `accept_ra` to `0`, so SLAAC never runs — while NetworkManager still
installed a v6 default route. The only global v6 address on the box belongs to
`tun0`, so source selection hands it to routes that egress `br0`. Packets leave
the LAN wearing the VPN's address and nothing returns; the socket sits in
`SYN-SENT`.

This is **not** the known dead-tunnel trap. The VPN was healthy — its gateway
pinged, v4 through it worked. `ip route get` says `dev br0` and looks innocent;
the tell is the **source address**, not the device. Anything that resolves AAAA
and does not fall back fast hangs the same way — `.NET` does not do Happy
Eyeballs, which is why `curl` masks the fault entirely.

Worked around per-process with `DOTNET_SYSTEM_NET_DISABLEIPV6=1`. Not fixed at
host level: the fix is `net.ipv6.conf.br0.accept_ra=2`, which changes IPv6
behaviour for k3s, libvirt and NFS on the lab's single point of failure and
deserves its own change window.

### The Authelia OIDC signing key was in a ConfigMap, not a Secret

Externalising `authelia/values.yaml` turned up a live exposure rather than a
git-hygiene problem. The chart's `files/configuration.oidc.jwk.yaml` branches on
how the key is supplied: `key.path` reads it from a mounted file at runtime,
but **`key.value` inlines it directly into the ConfigMap**. values.yaml used
`value:`, so the RSA key that signs every ID token for `auth.ddupan.top` was
sitting in plaintext in a ConfigMap — readable by anything with `get configmap`
in that namespace, and not encrypted at rest the way a Secret can be.

Fixed by moving all seven pieces of secret material into Kubernetes Secrets
(`secret.existingSecret` for six, `secret.additionalSecrets` for the JWKS key)
and referencing them by `path:`. The Secrets were built from the live
chart-generated Secret, so **no key material changed** — verified afterwards by
the JWKS endpoint still serving `kid=main` with the same modulus, meaning no
issued token was invalidated and nobody was logged out.

`authelia/values.yaml` is now committed. That was the last of the four configs
gitignored for embedded secrets.

### Incident — Authelia down ~5 minutes on the first attempt

The first upgrade put the JWKS key as a seventh key inside the `existingSecret`.
The chart projects that volume with an explicit `items:` list containing only
the six keys it generates, so the extra key was stored but **never mounted**.
Authelia died on `open /secrets/internal/…jwks.main.pem: no such file or
directory`, which cascaded into every other option appearing "required" because
the whole config template had failed to render.

Rolled back first to restore SSO, then fixed with `secret.additionalSecrets`,
which mounts a second Secret at `/secrets/<name>`. Two lessons: `helm template`
is not sufficient on its own — it happily rendered a config referencing a file
no volume projected — so the check that matters is cross-referencing every
`/secrets/...` reference against the rendered volumes' `items:`. And the
existingSecret volume mounts at `/secrets/internal`, not `/secrets/<name>`.

### Live S3 credentials were committed in the initial commit — now rotated

**Rotated 2026-07-28.** The leaked `anvAdmin` key is dead: verified denied
against the live endpoint. `anvReadOnly` and `terraform` were never exposed and
were left alone.

Rotating it broke `research-auto`, which turned out to be using the cluster-wide
admin key as its own S3 credentials. That dependency was invisible from this
repo — the app lives in `~/research-auto` and its Secret had been applied ad hoc,
with no owner references and its whole `k8s/` directory untracked. Finding it
needed a scan of every Secret in the cluster for the leaked key, not a grep of
this repo.

Fixed properly rather than by re-pointing it at the new admin key: `research-auto`
now has its own SeaweedFS identity scoped to the `research` bucket, written into
`~/research-auto/k8s/secrets.yaml` (gitignored, alongside the existing
`secrets.example.yaml` template) and applied. Both deployments were restarted —
these are env vars, so running pods keep the old value until recreated.

The orphaned `seaweedfs-s3-secret`, which the chart stopped generating once
`existingConfigSecret` was set but which still held the dead key, was deleted.
A cluster-wide scan now finds the leaked key in no Secret at all.

### Original exposure

`seaweedfs/values.yaml` carried the `anvAdmin` accessKey/secretKey inline and went
into git with the very first commit. They are still in history.

They survived three separate secret scans. The reason is instructive: the scan
regex looked for `secret[:=]`, and the key is written **`secretKey:`** — the word
"secret" is followed by "Key", not a colon. Together with the earlier `PASSWD:`
miss (case) and the `values.yaml`/`auth.json` misses (filename, not content),
that is three different ways the same class of scan fails.

Now externalised: the identities live in OpenBao at `kv/k8s/seaweedfs-s3`, ESO
syncs them, and the chart reads `filer.s3.existingConfigSecret` instead of
rendering credentials from values. **The leaked `anvAdmin` key still needs
rotating** — externalising stops it getting worse, it does not undo history.

### The cloudflared config was dead, not secret-bearing

Externalising `cloudflared/cloudflared.yaml` turned out to be the wrong fix: the
embedded ConfigMap and credentials Secret were **not in use at all**. Three
independent proofs — the config routed `idm.ddupan.top` to keycloak (retired
2026-07-10); it pointed `auth.ddupan.top` at `authelia:9091`, which 502s, while
Terraform had corrected that to `:80` and auth demonstrably works; and the
credentials volume mounted `subPath: <uuid>.json` against a Secret whose key was
`credentials-file`, so that mount never resolved.

The tunnel is token-managed and its ingress rules come from the Cloudflare API
via `cloudflared/terraform`. Confirmed on restart, which logged
`Updated to new configuration` carrying exactly the Terraform-managed rules, with
`authelia:80`. So both documents were deleted instead of being re-plumbed.

### Carried forward

- The OpenBao **PostgreSQL secrets engine** is the next step beyond static values:
  Gitea and Authelia both read their credentials only at startup, so short-TTL
  dynamic credentials would break them. Static roles (stable username, scheduled
  password rotation) plus something to restart the consumer is the shape that fits.
  `gitea.extraEnvSourceFile` and Authelia's `path:` indirection already read from
  files, which is what an OpenBao agent-injector writes.
- The `cloudflared-tunnel` Secret still carried the dead `credentials-file` key
  until today: `kubectl apply` MERGES, so removing it from the manifest did not
  remove it from the cluster. Removed with a JSON patch. Worth remembering whenever
  a key is dropped from a Secret.
- `.terraform.lock.hcl` is ignored in `openbao/` and `netbox/` but committed in
  the other two roots. That is backwards — provider versions should be pinned.
- Gitea's Ingress declares no class, and the only classes present are `contour`
  (retired) and `tailscale`. Gitea is therefore reachable only via the Cloudflare
  tunnel, i.e. it depends on the WAN.
- No Actions runner deployed; CI substrate undecided.
- **IPv6 is broken on the laptop** (see above). Worked around per-process only;
  `net.ipv6.conf.br0.accept_ra=2` still needs applying deliberately.
- `ddupan.top` still publishes SPF `~all` and DMARC `p=none`. Both should harden
  (`-all`, `p=quarantine`) once a few days of aggregate reports confirm DKIM
  passes — hardening before that would quarantine the lab's own mail.
