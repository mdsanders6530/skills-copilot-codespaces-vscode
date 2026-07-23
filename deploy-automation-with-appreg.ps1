<#
deploy-automation-with-appreg.ps1

Creates an App Registration + Service Principal, issues a client secret, attempts to grant Microsoft Graph application permissions,
and stores the appId/secret as a credential in an Azure Automation Account so runbooks can use it.

REQUIRES:
- Azure CLI (az) logged in
- Caller must be a tenant admin to grant application permissions (appRole assignments) to Microsoft Graph
- Az PowerShell module (optional, for storing credential into Automation Account)

USAGE:
.
\deploy-automation-with-appreg.ps1 -SubscriptionId <sub> -ResourceGroupName rg -AutomationAccountName aa-name -AppName "AzIntuneAgent-App" -Location eastus

NOTE: If automatic appRole assignment fails due to insufficient privileges, open an admin session and consent to the requested application permissions in the Azure Portal or use the "Grant admin consent" flow for the app registration.
#>
param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AutomationAccountName,
    [Parameter(Mandatory=$true)][string]$AppName,
    [string]$Location = 'eastus'
)

Set-StrictMode -Version Latest

function ExecAz([string]$cmd) {
    Write-Output "az $cmd"
    $raw = az $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az command failed: az $cmd`n$raw" }
    return $raw | ConvertFrom-Json
}

# 1) Set subscription
ExecAz "account set --subscription $SubscriptionId"

# 2) Ensure resource group
try { ExecAz "group show --name $ResourceGroupName -o json" | Out-Null }
catch { ExecAz "group create --name $ResourceGroupName --location $Location -o json" | Out-Null }

# 3) Ensure Automation Account
try { ExecAz "automation account show --name $AutomationAccountName --resource-group $ResourceGroupName -o json" | Out-Null }
catch { ExecAz "automation account create --name $AutomationAccountName --resource-group $ResourceGroupName --location $Location --sku Free -o json" | Out-Null }

# 4) Create App Registration
Write-Output "Creating App Registration: $AppName"
$app = ExecAz "ad app create --display-name '$AppName' -o json"
$appId = $app.appId
$appObjectId = $app.id
Write-Output "App created: appId=$appId, objectId=$appObjectId"

# 5) Create Service Principal for the app (if not exists)
try {
    $sp = ExecAz "ad sp create --id $appId -o json"
}
catch {
    Write-Warning "Service principal create returned or already exists. Attempting to read it."
    $sp = ExecAz "ad sp show --id $appId -o json"
}
$spObjectId = $sp.objectId
Write-Output "Service Principal objectId: $spObjectId"

# 6) Create client secret
Write-Output "Creating client secret..."
$secretRespRaw = az ad app credential reset --id $appId --append --credential-description "$AppName-automation-secret" --years 2 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to create client secret: $secretRespRaw" }
$secretResp = $secretRespRaw | ConvertFrom-Json
$clientSecret = $secretResp.password
Write-Output "Client secret created (keep secure)."

# 7) Resolve Microsoft Graph service principal and appRoles
$graphSp = ExecAz "ad sp show --id 00000003-0000-0000-c000-000000000000 -o json"
$graphSpObjectId = $graphSp.objectId
$appRoles = $graphSp.appRoles
$appRoleMap = @{}
foreach ($r in $appRoles) { $appRoleMap[$r.value] = $r.id }

$desiredPerms = @(
    'DeviceManagementManagedDevices.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All',
    'Group.ReadWrite.All',
    'User.ReadWrite.All',
    'Directory.ReadWrite.All'
)

# 8) Attempt to create appRoleAssignments for the app's service principal
Write-Output "Attempting to assign application permissions to the app service principal. Tenant admin required."
foreach ($perm in $desiredPerms) {
    if (-not $appRoleMap.ContainsKey($perm)) { Write-Warning "Graph appRole not found for $perm"; continue }
    $roleId = $appRoleMap[$perm]

    $body = @{ principalId = $spObjectId; resourceId = $graphSpObjectId; appRoleId = $roleId } | ConvertTo-Json
    try {
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignedTo" --headers "Content-Type=application/json" --body "$body" | Out-Null
        Write-Output "Assigned $perm"
    }
    catch {
        Write-Warning "Failed to assign $perm. Requires tenant admin consent. Error: $_"
    }
}

# 9) Create Automation credential asset with the appId as username and secret as password (if Az.Automation available)
if (Get-Command New-AzAutomationCredential -ErrorAction SilentlyContinue) {
    Import-Module Az.Automation -ErrorAction SilentlyContinue
    $secureSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
    $psCred = New-Object System.Management.Automation.PSCredential ($appId, $secureSecret)
    $credName = "AzIntuneAgent-AppReg-Cred"
    try {
        # Remove existing credential if present
        if (Get-AzAutomationCredential -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $credName -ErrorAction SilentlyContinue) {
            Remove-AzAutomationCredential -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $credName -Force
        }
        New-AzAutomationCredential -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $credName -Value $psCred | Out-Null
        Write-Output "Stored credential in Automation Account as asset: $credName"
    }
    catch {
        Write-Warning "Failed to create Automation credential asset: $_"
    }
}
else {
    Write-Warning "Az.Automation cmdlets not present. Create an Automation credential asset named 'AzIntuneAgent-AppReg-Cred' manually with username=$appId and password=<secret>"
}

Write-Output "Done. AppId: $appId"
Write-Output "IMPORTANT: Store client secret securely (Key Vault) and rotate regularly. If app role assignment failed, sign in as tenant admin and grant the listed application permissions to the registered app and click 'Grant admin consent'."
