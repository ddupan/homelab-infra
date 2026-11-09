# Windows counterpart of restore-drill.sh, for a workstation with the YubiKey and Gpg4win:
#   powershell -ExecutionPolicy Bypass -File infrastructure\openbao\restore-drill.ps1
# Rebuilds bao from the repo with the real playbooks in a throwaway VM on the laptop and
# restores the newest off-site snapshot. bao1 is not touched. Use Gpg4win's gpg.exe: Git
# for Windows ships its own gpg, whose agent does not see the smartcard.
# Three gpg decrypts (touch the YubiKey): the seal key, the snapshot, the recovery key.
# They go straight from gpg over ssh into the VM's tmpfs, never to disk on either side.
# -Keep leaves the VM for debugging: delete it afterwards, it holds real secrets
# (ssh laptop bash .bao-restore-drill-host.sh down).
param(
    [string]$Laptop = $(if ($env:LAPTOP) { $env:LAPTOP } else { 'panxiao81@192.168.10.127' }),
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$hostScript = '.bao-restore-drill-host.sh'
$remote = "ssh $Laptop bash $hostScript"

function Invoke-Pipeline([string]$pipeline) {
    # Through cmd, because PowerShell 5.1 re-encodes bytes between native commands, which
    # would corrupt the snapshot. cmd reports only the last command's exit code; the far
    # end rejects empty input and restore rejects a damaged snapshot or the wrong key.
    & cmd /c $pipeline
    if ($LASTEXITCODE -ne 0) { throw "failed: $pipeline" }
}

# CRLF from a Windows checkout would break bash.
Get-Content -Raw restore-drill-host.sh | & ssh $Laptop "tr -d '\r' > $hostScript"
if ($LASTEXITCODE -ne 0) { throw 'could not upload restore-drill-host.sh' }

try {
    Invoke-Pipeline "$remote up"
    Invoke-Pipeline "gpg -dq tpm-seal-key.gpg | $remote seal"
    Invoke-Pipeline "$remote fetch | gpg -dq | $remote push snapshot"
    Invoke-Pipeline "gpg -dq unseal-key.gpg | $remote push recovery"
    Invoke-Pipeline "$remote restore"
}
finally {
    if (-not $Keep) { Invoke-Pipeline "$remote down" }
}
