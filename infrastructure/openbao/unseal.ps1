# Windows counterpart of unseal.sh, for a workstation with the YubiKey and Gpg4win:
#   powershell -ExecutionPolicy Bypass -File infrastructure\openbao\unseal.ps1
# Use Gpg4win's gpg.exe — Git for Windows ships its own gpg with a separate agent that
# does not see the smartcard. Works on Windows PowerShell 5.1 and pwsh 7. The key is
# passed in-process to the HTTP body, never on a command line.
param(
    # By hostname: the listener cert is Let's Encrypt with DNS SANs only.
    [string]$BaoAddr = $(if ($env:BAO_ADDR) { $env:BAO_ADDR } else { 'https://bao.lab.ddupan.top:8200' }),
    [string]$KeyFile = (Join-Path $PSScriptRoot 'unseal-key.gpg')
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still default to TLS 1.0/1.1, which bao's listener refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$status = Invoke-RestMethod -Uri "$BaoAddr/v1/sys/seal-status" -TimeoutSec 10
if (-not $status.sealed) {
    Write-Host "bao is not sealed."
    exit 0
}

$key = (& gpg --quiet --decrypt $KeyFile) -join ''
if ($LASTEXITCODE -ne 0 -or -not $key) { throw "gpg could not decrypt $KeyFile (YubiKey plugged in?)" }
$body = @{ key = $key.Trim() } | ConvertTo-Json -Compress
$key = $null

$result = Invoke-RestMethod -Uri "$BaoAddr/v1/sys/unseal" -Method Put -Body $body `
    -ContentType 'application/json' -TimeoutSec 10
$body = $null

if ($result.sealed) {
    Write-Host "still sealed:" ($result | ConvertTo-Json -Compress)
    exit 1
}
Write-Host "unsealed"
