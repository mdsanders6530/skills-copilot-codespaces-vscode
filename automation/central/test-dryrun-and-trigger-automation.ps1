<#
Centralized copy of test-dryrun-and-trigger-automation.ps1
#>

# Copied from repo root test-dryrun-and-trigger-automation.ps1
param(
    [string]$AutomationSubscriptionId,
    [string]$ResourceGroupName,
    [string]$AutomationAccountName,
    [string]$AutopilotCsvPath = "..\autopilot-sample.csv",
    [string]$MappingJsonPath = "..\license-mapping.json",
    [string]$AutopilotRunbookName = "Autopilot-Onboard.runbook",
    [string]$LicenseRunbookName = "License-Assign.runbook",
    [string]$TenantId
)

Set-StrictMode -Version Latest

# This is a centralized copy intended to be the canonical location for team use.
# For the full editable version, see the repo root file: test-dryrun-and-trigger-automation.ps1

function Show-Info {
    Write-Output "Centralized dry-run script: use from automation\central. Defaults are relative to repo root."
}

Show-Info

# Optionally invoke the root script to run the full behaviour
$rootScript = Join-Path (Get-Location).Path "..\test-dryrun-and-trigger-automation.ps1"
if (Test-Path $rootScript) {
    Write-Output "Invoking repo-root script for full execution..."
    & $rootScript -AutomationSubscriptionId $AutomationSubscriptionId -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -AutopilotCsvPath $AutopilotCsvPath -MappingJsonPath $MappingJsonPath -AutopilotRunbookName $AutopilotRunbookName -LicenseRunbookName $LicenseRunbookName -TenantId $TenantId
}
else { Write-Warning "Repo root script not found at $rootScript. Maintain central copy if you want a standalone script." }
