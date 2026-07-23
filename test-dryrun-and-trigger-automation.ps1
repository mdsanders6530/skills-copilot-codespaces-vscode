<#
test-dryrun-and-trigger-automation.ps1

Runs local WhatIf checks against the AzIntuneAgent module, then (optionally) triggers the published runbooks in an Azure Automation Account with WhatIf=true.

Usage examples:
# Local only:
# .\test-dryrun-and-trigger-automation.ps1

# Run locally then trigger Automation dry-runs:
# .\test-dryrun-and-trigger-automation.ps1 -AutomationSubscriptionId <sub> -ResourceGroupName <rg> -AutomationAccountName <aa>

Notes:
- Run locally from the repo root where AzIntuneAgent.psm1 is present.
- Automation trigger requires Az PowerShell (Az.Accounts + Az.Automation) installed and the user signed in with permissions to start runbooks.
- The runbooks will be started with WhatIf=$true to avoid side-effects.
#>

param(
    [string]$AutomationSubscriptionId,
    [string]$ResourceGroupName,
    [string]$AutomationAccountName,
    [string]$AutopilotCsvPath = ".\autopilot-sample.csv",
    [string]$MappingJsonPath = ".\license-mapping.json",
    [string]$AutopilotRunbookName = "Autopilot-Onboard.runbook",
    [string]$LicenseRunbookName = "License-Assign.runbook",
    [string]$TenantId
)

Set-StrictMode -Version Latest

function Run-LocalWhatIf {
    Write-Output "== Local WhatIf checks =="
    $modulePath = Resolve-Path -Path "./AzIntuneAgent.psm1" -ErrorAction SilentlyContinue
    if (-not $modulePath) { Write-Warning "AzIntuneAgent.psm1 not found in current directory. Run from repo root."; return }

    Import-Module $modulePath.Path -Force -ErrorAction Stop

    Write-Output "Running New-AutopilotImportFromCsv -WhatIf against $AutopilotCsvPath"
    try {
        $apOut = New-AutopilotImportFromCsv -CsvPath $AutopilotCsvPath -WhatIf
        if ($apOut) { $apOut | ForEach-Object { Write-Output $_ } }
    }
    catch {
        Write-Warning "Local Autopilot WhatIf failed: $_"
    }

    Write-Output "Running Ensure-LicenseAssignment -WhatIf against $MappingJsonPath"
    try {
        $licOut = Ensure-LicenseAssignment -MappingPath $MappingJsonPath -WhatIf
        if ($licOut) { $licOut | ForEach-Object { Write-Output $_ } }
    }
    catch {
        Write-Warning "Local License WhatIf failed: $_"
    }
}

function Trigger-AutomationDryRun {
    param(
        [string]$SubscriptionId,
        [string]$Rg,
        [string]$AaName,
        [string]$ApRunbook,
        [string]$LicRunbook
    )

    Write-Output "== Automation dry-run trigger =="
    if (-not (Get-Command Connect-AzAccount -ErrorAction SilentlyContinue)) { throw "Az modules not available. Install Az.PowerShell modules and sign in." }
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null

    if (-not (Get-Command Start-AzAutomationRunbook -ErrorAction SilentlyContinue)) {
        Write-Warning "Az.Automation cmdlets not available locally. Install the Az.Automation module to enable runbook starts from this script."
        return
    }

    # Start Autopilot runbook with WhatIf = True (published runbook must exist)
    try {
        Write-Output "Starting runbook $ApRunbook (WhatIf=true)"
        $apJob = Start-AzAutomationRunbook -AutomationAccountName $AaName -ResourceGroupName $Rg -Name $ApRunbook -Parameters @{ WhatIf = $true } -ErrorAction Stop
        Write-Output "Autopilot runbook job started: Id=$($apJob.JobId)"
    }
    catch {
        Write-Warning "Failed to start Autopilot runbook: $_"
    }

    try {
        Write-Output "Starting runbook $LicRunbook (WhatIf=true)"
        $licJob = Start-AzAutomationRunbook -AutomationAccountName $AaName -ResourceGroupName $Rg -Name $LicRunbook -Parameters @{ WhatIf = $true } -ErrorAction Stop
        Write-Output "License runbook job started: Id=$($licJob.JobId)"
    }
    catch {
        Write-Warning "Failed to start License runbook: $_"
    }

    Write-Output "Jobs started. Monitor in portal: https://portal.azure.com/#blade/Microsoft_Automation/AutomationMenuBlade/overview/resourceId/$((Get-AzAutomationAccount -ResourceGroupName $Rg -Name $AaName).Id)"
}

# Main
Run-LocalWhatIf

if ($AutomationAccountName -and $ResourceGroupName -and $AutomationSubscriptionId) {
    try {
        Trigger-AutomationDryRun -SubscriptionId $AutomationSubscriptionId -Rg $ResourceGroupName -AaName $AutomationAccountName -ApRunbook $AutopilotRunbookName -LicRunbook $LicenseRunbookName
    }
    catch {
        Write-Warning "Automation dry-run trigger failed: $_"
    }
}
else {
    Write-Output "Automation account details not provided; skipping Azure Automation trigger. To trigger, supply -AutomationSubscriptionId, -ResourceGroupName, and -AutomationAccountName." 
}

Write-Output "Test script completed (dry-run)."
