<#
Azure Automation runbook: Autopilot-Onboard.runbook.ps1
Usage: Upload this runbook to an Azure Automation account, import AzIntuneAgent module and required Az/Microsoft.Graph modules.
This runbook prefers an Automation credential asset named 'AzIntuneAgent-AppReg-Cred' (username=appId, password=clientSecret).
If the credential asset is present the runbook uses the App Registration; otherwise it falls back to the Automation Managed Identity (MSI).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$AutopilotCsvPath,
    [Parameter(Mandatory=$false)]
    [string]$TargetGroupName = "Autopilot-Devices",
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

    # Connect to Azure using service principal
    Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $psCred -ErrorAction Stop | Out-Null

    # Connect to Microsoft Graph using client credentials (clientId = username, secret = password)
    $clientId = $psCred.UserName
    $clientSecret = $psCred.GetNetworkCredential().Password
    Connect-MgGraph -ClientId $clientId -TenantId $TenantId -ClientSecret $clientSecret -ErrorAction Stop | Out-Null
}
else {
    Write-Output "No AppReg credential found; attempting Managed Identity authentication."
    Connect-AzIntune -ManagedIdentity
}

# Import Autopilot devices
New-AutopilotImportFromCsv -CsvPath $AutopilotCsvPath -WhatIf:$WhatIf

# Ensure group and assign profile (profile name must exist/tweak as needed)
Ensure-IntuneGroupAssignment -GroupName $TargetGroupName -ProfileName "AutopilotProfile-Default" -WhatIf:$WhatIf

Write-Output "Autopilot onboarding runbook completed."
