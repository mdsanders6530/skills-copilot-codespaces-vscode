<#
Azure Automation runbook: License-Assign.runbook.ps1
Usage: Upload and run in Automation Account. Provide mapping JSON path with users/groups and skuPartNumbers.
This runbook looks for an Automation credential asset named 'AzIntuneAgent-AppReg-Cred' (username=appId, password=clientSecret).
If present it uses the App Registration; otherwise it attempts Managed Identity authentication.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$MappingJsonPath,
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    [switch]$WhatIf
)

Import-Module AzIntuneAgent -ErrorAction Stop

# Prefer App Registration credential stored as Automation credential asset
$psCred = $null
try { $psCred = Get-AutomationPSCredential -Name 'AzIntuneAgent-AppReg-Cred' -ErrorAction Stop } catch { }

if ($psCred) {
    Write-Output "Using stored App Registration credential asset."
    if (-not $TenantId) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Tenant) { $TenantId = $ctx.Tenant.Id }
        else { throw "TenantId parameter required when using AppReg credential" }
    }
    Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $psCred -ErrorAction Stop | Out-Null
    $clientId = $psCred.UserName
    $clientSecret = $psCred.GetNetworkCredential().Password
    Connect-MgGraph -ClientId $clientId -TenantId $TenantId -ClientSecret $clientSecret -ErrorAction Stop | Out-Null
}
else {
    Write-Output "No AppReg credential found; attempting Managed Identity authentication."
    Connect-AzIntune -ManagedIdentity
}

Ensure-LicenseAssignment -MappingPath $MappingJsonPath -WhatIf:$WhatIf

Write-Output "License assignment runbook completed."
