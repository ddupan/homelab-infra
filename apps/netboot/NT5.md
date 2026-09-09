# Installing NT5 (Windows 2000 / XP / Server 2003) over the network

NT5 predates WinPE/`install.wim`/`setup.exe`, so the modern pipeline in `WINDOWS.md` does
**not** apply. It also can't be `sanboot`ed (setup reboots mid-install and loses the virtual
CD). The workable network method that reuses our infra (SMB share + picker) is:

**boot an x86 WinPE → mount the share → run `winnt32.exe /makelocalsource` from the NT5 source.**

`/makelocalsource` copies the whole `i386` tree to the target disk first, so the share isn't
needed after the reboot into the real setup.

```
iPXE (Windows menu) → x86 WinPE (HTTP/wimboot)
   └─ startnet.cmd: drvload NIC → net use Z: \\192.168.10.127\win
        └─ winnt32.exe /syspart /tempdrive /makelocalsource /unattend:winnt.sif /noreboot
             └─ reboot → NT5 text-mode setup → GUI setup (all from local disk)
```

## Hard prerequisite: an x86 WinPE

`winnt32.exe` is **32-bit**. Our built WinPE is **x64**, which has no 32-bit support unless
`WinPE-WoW64` is added (an ADK/Windows step). So you need one of:

- **An x86 WinPE** — built the same way as the x64 one (see `WINDOWS.md` step 1), but from a
  **32-bit `boot.wim`**, i.e. a **Win10 x86** (or Win7 x86) ISO. Place it at
  `assets/WinPE/x86/` (the netboot.xyz Windows menu's arch toggle switches `${win_arch}` to
  `x86`). *No x86 Windows source is on this host yet — this is the missing ingredient.*
- **or** x64 WinPE + `dism /add-package WinPE-WoW64.cab` (Windows box).

Everything else below is editable on Linux (the source tree + answer file live on the share).

## 1. Put the NT5 source on the share

One folder per version under `/mnt/pool/win`, containing the extracted `i386` tree:

```
/mnt/pool/win/win2k/
├── i386/               ← extracted from the Win2000/XP/2003 ISO
├── $OEM$/              ← driver integration (see §3)
│   ├── Textmode/       ← mass-storage F6 driver(s) + txtsetup.oem
│   └── $1/Drivers/     ← PnP drivers (NIC/GPU/chipset) → copied to C:\Drivers
└── winnt.sif           ← unattended answer file (§2)
```

```bash
sudo mount -o loop,ro "Windows 2000 ....iso" /mnt/iso
mkdir -p /mnt/pool/win/win2k
cp -a /mnt/iso/I386 /mnt/pool/win/win2k/i386   # case as the ISO presents it
sudo umount /mnt/iso
```

The picker (`menu.cmd`) lists folders with a `setup.exe`; NT5 has no `setup.exe`, so either
add a tiny launcher or just run winnt32 by hand (below).

## 2. `winnt.sif` answer file (driver integration + unattend)

Skeleton — drop it in the version folder. Fill in the `[MassStorageDrivers]` /
`[OEMBootFiles]` from your controller's F6 package's `txtsetup.oem`:

```ini
[Data]
    AutoPartition = 0
    MsDosInitiated = 0
    UnattendedInstall = Yes

[Unattended]
    UnattendMode = FullUnattended
    OemPreinstall = Yes                 ; required for $OEM$ processing
    OemSkipEula = Yes
    FileSystem = LeaveAlone             ; or ConvertNTFS
    OemPnPDriversPath = Drivers\NIC;Drivers\Chipset   ; under C:\Drivers (from $OEM$\$1\Drivers)

[MassStorageDrivers]
    "Intel(R) SATA AHCI Controller" = "OEM"       ; the exact string from txtsetup.oem
    "IDE CD-ROM (ATAPI 1.2)/PCI IDE Controller" = "RETAIL"  ; keep inbox IDE too

[OEMBootFiles]
    txtsetup.oem
    iaahci.inf
    iaahci.sys
    iaahci.cat

[GuiUnattended]
    AdminPassword = *
    TimeZone = 210                      ; 210 = China Standard Time
    OEMSkipRegional = 1
    OemSkipWelcome = 1

[UserData]
    ProductKey = XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
    FullName = "user"
    OrgName = "home"
    ComputerName = *

[Identification]
    JoinWorkgroup = WORKGROUP

[Networking]
    InstallDefaultComponents = Yes
```

## 3. Drivers — two separate problems

**a) NIC for WinPE** (so the PE can reach the share): bake it into the x86 `boot.wim` and
`drvload` it — no Windows tooling:

```bash
wimlib-imagex update assets/WinPE/x86/sources/boot.wim 1 --command="add /path/to/nicdrv /Drivers/nic"
# startnet.cmd, BEFORE net use:   drvload X:\Drivers\nic\<driver>.inf
```

Use a **PE-compatible** driver (a Win10/7 *x86* NIC driver for an x86 PE) — *not* the XP one.

**b) Storage controller for the TARGET** (the `0x7B` BSOD): NT5 text-mode setup has no inbox
AHCI/NVMe/RAID. Put the controller's **F6 package** in `$OEM$\Textmode\` and reference it from
`[MassStorageDrivers]`/`[OEMBootFiles]` above. All editable on the Linux-hosted share.

**Easiest dodge (recommended where possible):**
- **VM → IDE disk** (`vmctl … --disk` uses `if=ide`) → inbox driver, **skip §3b entirely**.
- **Retro physical → BIOS SATA = IDE/Legacy/Compatibility** → inbox driver. (NT5 is BIOS-only;
  targets are old hardware that usually offers this.)

**c) Installed-OS drivers** (NIC/GPU/chipset for the running XP, distinct from the PE's NIC):
put XP-era drivers in `$OEM$\$1\Drivers\…` and list them in `OemPnPDriversPath` (§2). They get
copied to `C:\Drivers` and PnP-installed during GUI setup.

## 4. Run it (inside the x86 WinPE)

The target partition must exist, be **formatted (FAT32/NTFS)** and marked **active**
(`diskpart`: `create partition primary` → `format fs=ntfs quick` → `active`). Then:

```bat
net use Z: \\192.168.10.127\win
Z:\win2k\i386\winnt32 /s:Z:\win2k\i386 /unattend:Z:\win2k\winnt.sif ^
    /syspart:C: /tempdrive:C: /makelocalsource /noreboot
```

`/syspart` requires `/tempdrive`. On `/noreboot` completion, reboot the target off its **local
disk** — text-mode setup runs from the copied `$WIN_NT$.~BT`/`~LS`, then GUI setup, no network.

## Gotchas

- **XP/2000/2003 are BIOS/CSM only** — no UEFI. Boot the target (and the PE) in legacy mode.
- winnt32 under WinPE wants `/makelocalsource`; without it, it expects the source to remain
  reachable across the reboot (it won't be).
- Chinese media (like the Win2000 ISO here) installs fine; the answer file drives it in that
  language. TimeZone 210 = CST.
- **Activation:** volume/retail keys as appropriate; NT5 activation servers are long gone —
  use a VL edition/key for hands-off installs.
- If you'd rather not deal with any of this on real hardware: **install NT5 once, capture the
  disk, and PXE-boot Clonezilla** (already in the netboot menu) to clone it to targets.
