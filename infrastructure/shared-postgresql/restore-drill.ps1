# Windows counterpart of restore-drill.sh, for a workstation with the YubiKey and Gpg4win:
#   powershell -ExecutionPolicy Bypass -File infrastructure\shared-postgresql\restore-drill.ps1
# Builds an empty instance with the real playbooks in a throwaway VM on the laptop and
# imports the newest off-site dump. pg-prod is not touched. Use Gpg4win's gpg.exe: Git
# for Windows ships its own gpg, whose agent does not see the smartcard.
# One gpg decrypt (touch the YubiKey). The dump goes straight from gpg over ssh into the
# VM's tmpfs, never to disk on either side.
# -Keep leaves the VM for debugging: delete it afterwards, it holds real data
# (ssh laptop bash .pg-restore-drill-host.sh down).
param(
    [string]$Laptop = $(if ($env:LAPTOP) { $env:LAPTOP } else { 'panxiao81@192.168.10.127' }),
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$hostScript = '.pg-restore-drill-host.sh'
$remote = "ssh $Laptop bash $hostScript"

function Invoke-Pipeline([string]$pipeline) {
    # Through cmd, because PowerShell 5.1 re-encodes bytes between native commands, which
    # would corrupt the dump. cmd reports only the last command's exit code; push tests
    # the zstd stream, so a failed or partial decrypt is still caught.
    & cmd /c $pipeline
    if ($LASTEXITCODE -ne 0) { throw "failed: $pipeline" }
}

# CRLF from a Windows checkout would break bash.
Get-Content -Raw restore-drill-host.sh | & ssh $Laptop "tr -d '\r' > $hostScript"
if ($LASTEXITCODE -ne 0) { throw 'could not upload restore-drill-host.sh' }

try {
    Invoke-Pipeline "$remote up"
    Invoke-Pipeline "$remote fetch | gpg -dq | $remote push"
    Invoke-Pipeline "$remote restore"
}
finally {
    if (-not $Keep) { Invoke-Pipeline "$remote down" }
}
