<#
Deployment helper for Azure Automation: creates Automation Account (if missing), enables System Assigned Managed Identity,
and attempts to import runbooks and upload module files where Az.Automation cmdlets are available.
Run interactively from an admin PowerShell session with Az and Azure CLI installed.
#>
param(
    [Parameter(Mandatory=$true)] [string]$SubscriptionId,
    [Parameter(Mandatory=$true)] [string]$ResourceGroupName,
    [Parameter(Mandatory=$true)] [string]$AutomationAccountName,
    [Parameter(Mandatory=$true)] [string]$ModuleFilePath,
    [Parameter(Mandatory=$true)] [string[]]$RunbookFiles
)

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction SilentlyContinue

Write-Output "Logging into Azure..."
Connect-AzAccount -Subscription $SubscriptionId

# Create resource group if missing
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Output "Creating resource group $ResourceGroupName"
    New-AzResourceGroup -Name $ResourceGroupName -Location eastus
}

# Create Automation Account if missing
$aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
if (-not $aa) {
    Write-Output "Creating Automation Account $AutomationAccountName"
    New-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -Location eastus
}
else { Write-Output "Found Automation Account: $AutomationAccountName" }

Write-Output "Enabling System Assigned Managed Identity on Automation Account (requires Azure CLI)
If Azure CLI not available, enable via portal."
$azCli = Get-Command az -ErrorAction SilentlyContinue
if ($azCli) {
    $cmd = "az automation update --name $AutomationAccountName --resource-group $ResourceGroupName --set identity.type=SystemAssigned"
    Write-Output "Running: $cmd"
    Invoke-Expression $cmd
}
else { Write-Warning "Azure CLI not found; enable managed identity in portal or install Azure CLI." }

# Display managed identity principal
Start-Sleep -Seconds 3
$aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
if ($aa.Identity -and $aa.Identity.PrincipalId) {
    Write-Output "Automation Managed Identity principalId: $($aa.Identity.PrincipalId)"
    Write-Output "Grant Microsoft Graph permissions to this identity via Azure AD enterprise app or use a service principal with consent."
} else { Write-Warning "Managed Identity not yet available. Verify in portal or retry." }

# Upload module: AzIntuneAgent.psm1
if (-not (Test-Path $ModuleFilePath)) { throw "Module file not found: $ModuleFilePath" }

# Try to import module via Az.Automation cmdlets if present
if (Get-Command New-AzAutomationModule -ErrorAction SilentlyContinue) {
    Write-Output "Importing module to Automation Account..."
    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($ModuleFilePath)
    # Zip the module file into a folder structure expected by Automation (ModuleName/ModuleFile.psm1)
    $tempDir = Join-Path $env:TEMP "aa_module_$moduleName"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tempDir
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    Copy-Item $ModuleFilePath -Destination (Join-Path $tempDir (Split-Path $ModuleFilePath -Leaf))
    $zipPath = "$tempDir.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
    New-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $moduleName -ContentLinkUri ("file:///$zipPath") -ErrorAction SilentlyContinue
    Write-Output "Module import attempted; verify in Automation Account > Modules gallery."
}
else {
    Write-Warning "Az.Automation module missing. Upload module via Azure portal: Automation Account > Modules > Add a module (upload zip)."
}

# Import runbooks
foreach ($rb in $RunbookFiles) {
    if (-not (Test-Path $rb)) { Write-Warning "Runbook file missing: $rb"; continue }
    if (Get-Command Import-AzAutomationRunbook -ErrorAction SilentlyContinue) {
        Write-Output "Importing runbook $rb"
        Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Path $rb -Type PowerShell -Force
        Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name (Split-Path $rb -Leaf -Resolve:$false)
    }
    else {
        Write-Output "Az.Automation runbook import cmdlets not available. Create runbook via portal and paste content of $rb"
    }
}

Write-Output "Deployment helper finished. Next: grant Graph API delegated/application permissions to the Automation managed identity and consent as tenant admin. Then install Microsoft.Graph.PowerShell and Az modules into the Automation Account, and test runbooks with -WhatIf."