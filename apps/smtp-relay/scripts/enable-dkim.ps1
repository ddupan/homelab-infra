# DKIM step 1 of 2: create the signing config (disabled) and PRINT the exact CNAME
# targets. The 2025 CNAME format includes a per-tenant character only Exchange knows,
# so we must read Selector1CNAME/Selector2CNAME from here, publish them, THEN enable.
#
#     ! pwsh ~/services/apps/smtp-relay/scripts/enable-dkim.ps1
# Sign in as a tenant admin. Paste the CNAME values back so DNS can be updated.
param(
  [string]$Domain = 'ddupan.top'
)
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -Device -ShowBanner:$false

# Create directly (disabled). Don't pre-check with Get — on a missing domain it only
# WARNS (not errors), which defeats try/catch. Catch the "already exists" case instead.
try {
  New-DkimSigningConfig -DomainName $Domain -KeySize 2048 -Enabled $false -ErrorAction Stop | Out-Null
  Write-Host "Created DKIM config for $Domain (disabled)."
} catch {
  if ("$($_.Exception.Message)" -match 'already exist') {
    Write-Host "DKIM config already exists — continuing."
  } else {
    Write-Host "New-DkimSigningConfig failed: $($_.Exception.Message)"
    Disconnect-ExchangeOnline -Confirm:$false
    return
  }
}

Write-Host "`n== PUBLISH THESE EXACT CNAME TARGETS (paste them back) =="
Get-DkimSigningConfig -Identity $Domain | Format-List Name, Enabled, Status, Selector1CNAME, Selector2CNAME
Write-Host "After the CNAMEs are updated + resolving, run scripts/enable-dkim-finish.ps1 to enable."
Disconnect-ExchangeOnline -Confirm:$false
