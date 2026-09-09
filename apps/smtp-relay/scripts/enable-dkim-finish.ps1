# DKIM step 2 of 2: enable signing, once the CNAME targets from enable-dkim.ps1 are
# published and resolving. Validates the CNAMEs and turns on DKIM signing.
#
#     ! pwsh ~/services/apps/smtp-relay/scripts/enable-dkim-finish.ps1
param(
  [string]$Domain = 'ddupan.top'
)
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -Device -ShowBanner:$false
try {
  Set-DkimSigningConfig -Identity $Domain -Enabled $true -ErrorAction Stop
  Write-Host "DKIM enabled for $Domain."
} catch {
  Write-Host "Enable failed: $($_.Exception.Message)"
  Write-Host "If it mentions CNAME records, they aren't visible to Exchange yet — wait and re-run."
}
Get-DkimSigningConfig -Identity $Domain | Format-List Name, Enabled, Status, Selector1CNAME, Selector2CNAME
Disconnect-ExchangeOnline -Confirm:$false
