# Installing Windows via netboot.xyz

Works for KVM VMs and physical machines. Windows Setup needs a real filesystem for the
~4 GB `install.wim`, so the flow is: **wimboot → WinPE (HTTP) → SMB media → setup.exe**.

> This covers **NT6+ (Vista/7/8/10/11, Server 2008–2025)**. Older Windows works completely
> differently — see **`NT5.md`** for Windows 2000/XP/Server 2003, and **`9x.md`** for
> Windows 95/98/ME (via win98-quickinstall's Linux installer).

```
iPXE Windows menu
  └─ wimboot loads WinPE (boot.wim) over HTTP from this host   (assets/WinPE/x64/)
       └─ WinPE boots to a cmd prompt; wpeinit brings up the NIC
            └─ net use → mount the SMB share with the extracted ISO
                 └─ setup.exe → installs Windows to the local disk
```

## Already set up on the server (done)

- **SMB share** `\\192.168.10.127\win` — **guests get read-only, passwordless** (WinPE mounts
  it this way); the AD user **`panxiao81` has read-write** (`write list = DDUPAN\panxiao81`) for
  staging images/media. Backed by ZFS dataset `data/win` → `/mnt/pool/win`. Holds `menu.cmd`
  (the version picker) and the `winpe-build/` driver kit. Managed by the `samba_member` Ansible
  role (`samba-ad/`), not a hand-edited `smb.conf`.
- **`win_base_url`** = `http://192.168.10.127:8080/WinPE` — set in both
  `config/menus/local-vars.ipxe` and `config/menus/boot.cfg` (the latter covers clients whose
  firmware is already iPXE and skips `local-vars`).
- **WinPE** built into `assets/WinPE/x64/` (base PE extracted from a Server 2025 ISO; NIC/
  storage drivers injected with **DISM** — see step 1 / Driver notes), with a `startnet.cmd`
  that brings up networking, auto-mounts the share, and launches the picker.
- Only remaining step for a real install: drop a version folder onto the share (step 2).

## Verified (PXE-tested)

Driven end-to-end in a KVM VM on `br0`: iPXE Windows menu → wimboot loaded the WinPE over
HTTP → WinPE booted → `startnet.cmd` ran `wpeinit`, mounted `\\192.168.10.127\win`, and
launched `menu.cmd`, which showed the (empty) picker. So the whole path works; adding a
version folder makes it installable. Note: give the target **≥4 GB RAM** (2 GB bugchecks the
RAM-loaded WinPE and reboots).

## What you do

### 1. Build WinPE

The WinPE at `assets/WinPE/x64/` is **already built and PXE-tested** (see "Verified" below).
Two ways to (re)build it:

**A. On Linux, no Windows box needed (how it was built here).** A Windows installation ISO's
`sources/boot.wim` *is* a modern WinPE. Extract its bare-PE image with `wimlib-imagex` and
inject a startup script that auto-mounts the share and runs the picker:

```bash
ISO=~/zh-cn_windows_server_2025_..._x64_dvd.iso   # any modern Windows/Server ISO
OUT=/home/panxiao81/services/apps/netboot/assets/WinPE/x64
sudo mount -o loop,ro "$ISO" /mnt/winiso
mkdir -p "$OUT/boot" "$OUT/sources"
cp /mnt/winiso/bootmgr "$OUT/bootmgr"
cp /mnt/winiso/bootmgr.efi "$OUT/bootmgr.efi"
cp /mnt/winiso/boot/bcd "$OUT/boot/bcd"
cp /mnt/winiso/boot/boot.sdi "$OUT/boot/boot.sdi"
# export image 1 ("Windows PE") as a single bootable wim
wimlib-imagex export /mnt/winiso/sources/boot.wim 1 "$OUT/sources/boot.wim" --boot
# auto-run our startup: wpeinit + mount \\host\win + launch menu.cmd  (startnet.cmd is CRLF)
wimlib-imagex update "$OUT/sources/boot.wim" 1 --command="delete --force /Windows/System32/startnet.cmd"
wimlib-imagex update "$OUT/sources/boot.wim" 1 --command="add /path/to/startnet.cmd /Windows/System32/startnet.cmd"
sudo umount /mnt/winiso
```

Use the **newest** Windows/Server ISO you have — a WinPE installs any OS at or below its
version. Drivers are injected separately with **DISM** (see **Driver notes**), so the baked-in
`startnet.cmd` no longer needs `drvload` — it just brings up networking (with a DHCP retry
loop, since a freshly-loaded NIC can be a few seconds behind the first DISCOVER) and launches
the picker:

```bat
wpeinit                                REM PnP auto-loads the DISM-injected NIC driver
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f
:netwait                               REM retry until a real 192.168.10.x lease appears
wpeutil InitializeNetwork
ipconfig | find "192.168.10." >nul && goto neton
ipconfig /renew >nul & ping 127.0.0.1 -n 4 >nul & goto netwait
:neton
net use Z: \\192.168.10.127\win
if exist Z:\menu.cmd call Z:\menu.cmd
cmd
```

**B. On a Windows box (Windows ADK).** `copype amd64 C:\winpe` → `MakeWinPEMedia /ISO ...`,
then copy the ISO/media contents into `assets/WinPE/x64/`. Edit `boot.wim`'s
`Windows\System32\startnet.cmd` to the same script as above. Use this if you want ADK's
optional components or a custom PE. (This same ADK box is where drivers get DISM-injected —
see Driver notes.)

Either way the tree must be:

```
assets/WinPE/x64/
├── bootmgr
├── bootmgr.efi
├── boot/bcd            (BCD store — the menu also tries Boot/BCD)
├── boot/boot.sdi
└── sources/boot.wim    (your WinPE image, single bootable index)
```

netboot.xyz loads exactly those five files from `${win_base_url}/x64/`. (`wimboot` itself is
fetched from public `boot.netboot.xyz` — fine as long as the host has internet.) Give WinPE
**≥4 GB RAM** on the target — the wim is RAM-loaded and 2 GB bugchecks → reboot.

### 2. Populate the SMB share with install media

Put each Windows version in **its own subfolder** under `/mnt/pool/win` — extract the ISO
*files* (not the .iso). One WinPE installs all of them; you do NOT need a WinPE per version.

```bash
sudo mount -o loop Win11_24H2.iso /mnt/iso
mkdir -p /mnt/pool/win/win11-24h2
cp -a /mnt/iso/. /mnt/pool/win/win11-24h2/
sudo umount /mnt/iso
# repeat for win10-22h2/, server2022/, server2025/, ...
```

Result:

```
/mnt/pool/win/
├── menu.cmd            ← version picker (already installed)
├── win11-24h2/         ← setup.exe, sources/install.wim, ...
├── win10-22h2/
└── server2025/
```

Editions (Home/Pro/Enterprise) usually live inside one ISO's `install.wim`; `setup.exe`
lets you pick, so they don't need separate folders. See "Multiple versions" below.

### 3. Boot a target → install

1. PXE boot → **Windows** → **Load Microsoft Windows Installer** (uses `win_base_url`).
   On real hardware confirm WinPE actually got a `192.168.10.x` (`ipconfig`); if the onboard
   NIC won't network, use a **USB Ethernet dongle** — see **Driver notes**.
2. At the WinPE `cmd` prompt (startnet usually does this for you):
   ```bat
   wpeinit
   net use Z: \\192.168.10.127\win
   Z:\menu.cmd            REM pick a version; launches <folder>\sources\setup.exe
   ```
3. Pick a version → click through Setup → install to the local disk.
4. **After Setup's first reboot, boot the LOCAL DISK, not PXE** — otherwise it loops back into
   netboot and the install looks like it "restarted." (One-time boot menu, or move the disk
   above the network in the BIOS boot order.)

> **Win11 24H2/25H2 gotcha — launch `sources\setup.exe`, not the media-root `setup.exe`.** In
> 24H2+ the root `setup.exe` is the new "modern setup" front-end, meant for booting from real
> USB/DVD media or upgrading from within Windows; started from a bare WinPE prompt it **exits
> partway** ("quits in half"). The classic engine at `<folder>\sources\setup.exe` is PE-friendly.
> `menu.cmd` already prefers `sources\setup.exe` (falling back to the root one for older media).

## Multiple Windows versions

One x64 WinPE handles every x64 Windows (10/11, Server 2019–2025, all editions) — as long
as the WinPE is at least as new as the newest OS you install. Manage versions purely as the
folder library on the share; `menu.cmd` auto-lists every subfolder that contains a
`setup.exe` and launches the one you choose.

**Make it hands-off** by baking the mount + picker into WinPE so every boot lands on the
menu. When building WinPE, edit `mount\Windows\System32\startnet.cmd` (in the mounted
`boot.wim`) to:

```bat
wpeinit
rem allow passwordless (guest) SMB from WinPE
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f
net use Z: \\192.168.10.127\win
Z:\menu.cmd
```

**Unattended per version:** drop an `autounattend.xml` in a version folder and launch it with
`setup.exe /unattend:%~dp0autounattend.xml` (you can add per-folder entries to `menu.cmd`).
Each version can have its own answer file (edition index, product key, partitioning).

**x86 / ARM64:** only these need a second WinPE — place it in `assets/WinPE/x86/` (the Windows
menu's arch toggle switches `${win_arch}`). Rarely needed.

**Advanced — per-version entries in the iPXE menu** (choose the version *before* WinPE, e.g.
for fully automated imaging): pass a config into WinPE via extra `initrd` lines in
`windows.ipxe` so WinPE auto-installs a specific folder. See
[netbootxyz discussion #757](https://github.com/netbootxyz/netboot.xyz/discussions/757).
For interactive use, the `menu.cmd` picker is simpler and needs no iPXE changes.

## Driver notes (mainly physical machines)

WinPE must have the target's **NIC driver** (to reach the share) and Setup must have the
**storage driver** (to see the disk). VMs rarely need this; real hardware often does.

The build's reduced WinPE driver set is missing most modern **Intel** desktop NICs: it ships
`e1i`/`e1e`/`e1g` (I350/82575/8257x-era) but **not** `e1d` (I217/I218/**I219**) or `e2f`
(**I225/I226** 2.5G). Symptom: WinPE boots but `net use` fails because there is no link —
no NIC was ever loaded. Realtek onboard NICs (RTL8111/8168/8125) are likewise absent, and so
is **virtio-net** (needed for KVM installs with a virtio NIC).

### How the current image gets its drivers: DISM injection on `winadmin`

Drivers are injected into `boot.wim`'s driver store with **DISM** on the Windows ADK box
(`winadmin`, `192.168.10.6`). This is the proper method: they become real PnP drivers that load
automatically at boot — no `drvload`. A ready-to-run **build kit** lives on the share at
`\\192.168.10.127\win\winpe-build\`:

```
winpe-build/
├── boot.wim                 ← image to service (copy of the live one)
├── drivers/
│   ├── Intel-1G/            e1dn (I219 — but see ⚠ box), e1r (I210/211/350), v1q (82575/6/80)
│   ├── Intel-2.5G/          e2f (I225/I226)                                            NDIS68
│   ├── virtio-NetKVM/       netkvm (virtio-net) + netkvmp.exe/netkvmco.exe
│   ├── virtio-viostor/      viostor (virtio-blk)
│   └── virtio-vioscsi/      vioscsi (virtio-scsi)
├── startnet.cmd             ← no-drvload version (PnP loads drivers; DHCP retry loop)
├── build-winpe.cmd          ← one-click DISM script
└── READ-ME-FIRST.txt
```

Rebuild on `winadmin` (the DISM mount dir must be **local**, not the share):

```bat
robocopy \\192.168.10.127\win\winpe-build C:\winpe-build /E
:: Start menu -> "Deployment and Imaging Tools Environment" -> Run as administrator
cd /d C:\winpe-build
build-winpe.cmd            :: mounts boot.wim, drops any old \Drivers tree, DISM /add-driver, commits
copy /y C:\winpe-build\boot.wim \\192.168.10.127\win\winpe-build\boot.new.wim
```

Then on this host, back up the live image and swap it in (netboot serves it statically — no
restart, and a size change is fine, the BCD loads `boot.wim` by name):

```bash
cd assets/WinPE/x64/sources
cp -a boot.wim boot.wim.prev
cp /mnt/pool/win/winpe-build/boot.new.wim boot.wim
```

`build-winpe.cmd` is essentially:

```bat
dism /Mount-Image /ImageFile:.\boot.wim /Index:1 /MountDir:.\mount
rmdir /s /q .\mount\Drivers                                    :: drop any old drvload tree
copy /y .\startnet.cmd .\mount\Windows\System32\startnet.cmd
dism /Image:.\mount /Add-Driver /Driver:.\drivers /Recurse /ForceUnsigned
dism /Image:.\mount /Get-Drivers                              :: confirm the NIC driver is listed
dism /Unmount-Image /MountDir:.\mount /Commit
```

Use the **current Win11 24H2 / 10.1.26100 ADK** — servicing a 26100 `boot.wim` with an older
DISM fails (*"image version is higher than the DISM version"*).

> **⚠ Verdict — the onboard Intel I219 does NOT work in this (build-26100) WinPE with any
> driver. Use a USB Ethernet dongle.** On a real I219 (`DEV_550B`, recent Lenovo board) all
> three Intel drivers failed to move a single frame in *either* direction (no DHCP; a static-IP
> ping gets no ARP reply — confirmed with `tcpdump` on the host, which saw nothing from the NIC's
> MAC):
> - `e1dn` v20.0.3.24 **and** the Lenovo-OEM `e1dn` v20.0.2.19 → link shows "connected", **no traffic**.
> - `e1d` v12.19.2.65 → **no traffic**, and `netsh …set interface admin=disabled` **bugchecks with
>   `PNP_WATCHDOG`** (the driver can't even cleanly stop the device).
>
> PXE firmware works on the same port (its own minimal driver), so it's specifically the I219
> datapath under build-26100 WinPE — a known regression on newer PE builds. **Fix: a USB GbE
> dongle** (Realtek RTL8153/8156 is inbox in WinPE 26100 — ours worked with nothing injected).
> The onboard I219 is fine once *real* Windows is installed. An older WinPE base (Win10 22H2 /
> Server 2022, build ≤20348) *might* also work but is untested.

Intel driver sources: **Intel Wired driver 31.2**
(`downloadmirror.intel.com/921523/Wired_driver_31.2_x64.zip`), `PRO1000\Winx64\NDIS68` +
`PRO2500\Winx64\NDIS68` subfolders; the I219 `e1dn` in the current kit is the Lenovo OEM package
(`e1dn` 20.0.2.19). virtio drivers from `virtio-win-0.1.285.iso` (`~/virtio-win-0.1.285.iso`),
`<driver>/w11/amd64` folders — **keep `netkvmp.exe`**, `netkvm.inf`'s `[CopyFiles]` requires it.

**State:** the live `boot.wim` is a DISM build whose driver store (`oem*.inf`) holds `e1dn`
(OEM I219 — moot, see box), `e1r`/`v1q` (I210/211/350), `e2f` (I225/226) and
`netkvm`/`viostor`/`vioscsi` (virtio) — so it still covers other Intel NICs and KVM VMs, and the
`e1d` that `PNP_WATCHDOG`'d is deliberately excluded. The I219 machine installs via a **USB
dongle**, and Setup ran once the picker used `sources\setup.exe`. (An earlier `drvload` build was
VM-verified with a virtio-net NIC reaching the share.)

### Alternative: `drvload` at runtime (Linux build, no Windows box)

The image can also be built entirely on Linux with `wimlib-imagex`: stage the driver
`.inf`/`.sys`/`.cat` files inside `boot.wim` under `\Drivers` and `drvload` them from
`startnet.cmd` before networking. This is how it was *first* built — it's the fallback, since
`drvload` only loads into the running PE (no persistent driver store) and can load several
matching drivers at once, leaving PnP to bind whichever it ranks highest (which is how the flaky
`e1dn` got picked early on):

```bat
for /r X:\Drivers %%i in (*.inf) do drvload "%%i"   REM filename-agnostic; non-matching INFs fail harmlessly
wpeinit
wpeutil InitializeNetwork
```
```bash
WIM=assets/WinPE/x64/sources/boot.wim
printf '%s\n' \
  "add /path/to/stage/Drivers /Drivers" \
  "delete --force /Windows/System32/startnet.cmd" \
  "add /path/to/startnet.cmd /Windows/System32/startnet.cmd" \
  | wimlib-imagex update "$WIM" 1
```

> **Gotcha `drvload` fails with `0x80070002` (FILE_NOT_FOUND):** the INF's `[CopyFiles]`
> references a file you trimmed (e.g. NetKVM's `netkvmp.exe`). Keep the whole driver folder —
> strip only `*.pdb`/readme.

### Storage drivers

- Storage/RAID (Intel VMD/RST) drivers usually also need loading in Setup (or slipstream into
  `install.wim`). NVMe/AHCI are typically inbox.
- **KVM:** using virtio disk/NIC → the virtio drivers above are baked in; or give the VM a
  **SATA disk + e1000 NIC** (both inbox) to skip driver work entirely.

## Gotcha: guest SMB from WinPE

Modern Windows blocks "insecure guest" logons by policy. WinPE usually allows it, but if
`net use` fails with **system error 1272 / 5**, enable it in the running WinPE:

```bat
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f
```

(To make it permanent, set the same key offline in the mounted `boot.wim`.) Alternatively,
switch the share to a real user + password — but do it in the `samba_member` role
(`samba-ad/`), **not** `/etc/samba/smb.conf` directly (Ansible regenerates that file). The
`[win]` share already grants the AD user `panxiao81` read-write via `write list`.

## Later: unattended installs

Drop an `autounattend.xml` at the root of the SMB media (or bake into WinPE via
`startnet.cmd` running `wpeinit` + `net use` + `setup.exe /unattend:...`) for zero-touch.
