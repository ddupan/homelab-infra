# Enables Authenticated SMTP (SMTP AUTH) on noreply@ddupan.top so OAuth SMTP works.
# Run it yourself (interactive admin device-login):
#     ! pwsh ~/services/apps/smtp-relay/scripts/enable-smtp-auth.ps1
# At the prompt, open https://microsoft.com/devicelogin and sign in as a tenant ADMIN.
param(
  [string]$Mailbox = 'noreply@ddupan.top'
)
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -Device -ShowBanner:$false

$mbx = Get-CASMailbox -Identity $Mailbox -ErrorAction SilentlyContinue
if (-not $mbx) {
  Write-Host "Mailbox '$Mailbox' isn't provisioned yet (licensing can take a few minutes). Wait and re-run."
} else {
  Set-CASMailbox -Identity $Mailbox -SmtpClientAuthenticationDisabled:$false
  Write-Host "== Authenticated SMTP status =="
  Get-CASMailbox -Identity $Mailbox | Format-List Name, SmtpClientAuthenticationDisabled
}
Disconnect-ExchangeOnline -Confirm:$false
