<#
deploy-automation-with-graph-perms.ps1

Creates an Azure Automation Account with System Assigned Managed Identity and attempts to grant Microsoft Graph application permissions
to the Automation managed identity by creating app role assignments against the Microsoft Graph service principal.

REQUIRES:
- Azure CLI (az) logged in as a Tenant Administrator
- PowerShell (Windows)

USAGE EXAMPLE:
.\deploy-automation-with-graph-perms.ps1 -SubscriptionId <sub> -ResourceGroup rg-test -Location eastus -AutomationAccountName aa-intune-agent

NOTE: Assigning application permissions to service principals requires tenant admin consent. The script will attempt to create appRoleAssignments and will fail if the caller is not an admin.
#>
param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AutomationAccountName,
    [string]$Location = 'eastus'
)

Set-StrictMode -Version Latest

function ExecAz([string]$cmd) {
    Write-Output "az $cmd"
    $out = az $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az command failed: az $cmd`n$out" }
    return $out | ConvertFrom-Json
}

# 1) Set subscription
ExecAz "account set --subscription $SubscriptionId"

# 2) Create resource group if missing
$rg = ExecAz "group show --name $ResourceGroupName --query name -o json" 2>$null
if (-not $rg) {
    ExecAz "group create --name $ResourceGroupName --location $Location | ConvertTo-Json"
}

# 3) Create Automation Account
try {
    $aa = ExecAz "automation account show --name $AutomationAccountName --resource-group $ResourceGroupName -o json"
    Write-Output "Found existing Automation Account: $AutomationAccountName"
}
catch {
    Write-Output "Creating Automation Account: $AutomationAccountName"
    ExecAz "automation account create --name $AutomationAccountName --resource-group $ResourceGroupName --location $Location --sku Free -o json"
}

# 4) Enable system-assigned identity for Automation Account
$aaResId = "$(az automation account show --name $AutomationAccountName --resource-group $ResourceGroupName --query id -o tsv)"
if (-not $aaResId) { throw "Failed to locate Automation Account resource id" }
Write-Output "Enabling system assigned identity on Automation Account..."
az resource update --ids $aaResId --set identity.type=SystemAssigned | Out-Null
Start-Sleep -Seconds 5

# 5) Read managed identity principal/object id
$aaInfo = ExecAz "resource show --ids $aaResId -o json"
$miPrincipalId = $aaInfo.identity.principalId
if (-not $miPrincipalId) { throw "Managed identity principalId not available yet. Please retry after a moment." }
Write-Output "Automation managed identity principalId: $miPrincipalId"

# 6) Resolve Microsoft Graph service principal
Write-Output "Resolving Microsoft Graph service principal (appId 00000003-0000-0000-c000-000000000000)..."
$graphSp = ExecAz "ad sp show --id 00000003-0000-0000-c000-000000000000 -o json"
$graphSpObjectId = $graphSp.objectId
if (-not $graphSpObjectId) { throw "Failed to locate Microsoft Graph service principal in this tenant." }

# 7) Desired application permissions (appRole values as listed by Graph). These names must match appRole 'value' fields in Graph's service principal.
$permissions = @(
    'DeviceManagementManagedDevices.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All',
    'Group.ReadWrite.All',
    'User.ReadWrite.All',
    'Directory.ReadWrite.All'
)

# 8) Fetch Graph service principal appRoles and build mapping
$graphAppRoles = $graphSp.appRoles
$appRoleMap = @{}
foreach ($r in $graphAppRoles) { $appRoleMap[$r.value] = $r.id }

# 9) For each desired permission, create an appRoleAssignment on the Automation managed identity's service principal
#    API: POST https://graph.microsoft.com/v1.0/servicePrincipals/{managedIdentityObjectId}/appRoleAssignedTo
#    Body: { "principalId": "{managedIdentityObjectId}", "resourceId": "{graphServicePrincipalObjectId}", "appRoleId": "{roleId}" }

# Retrieve the managed identity's service principal objectId (a service principal exists for MSI)
# Use az ad sp list --filter "servicePrincipalNames/any(c:c eq '{miPrincipalId}')" to find it
$miSp = ExecAz "ad sp list --filter servicePrincipalNames/any(c:c eq '$miPrincipalId') -o json | ConvertTo-Json" 2>$null
# above can return array; try simpler search
$miServicePrincipal = az ad sp list --filter "servicePrincipalNames/any(c:c eq '$miPrincipalId')" | ConvertFrom-Json
if ($miServicePrincipal -is [System.Array]) { $miServicePrincipal = $miServicePrincipal | Select-Object -First 1 }
if (-not $miServicePrincipal) {
    Write-Warning "Could not locate service principal for the Automation managed identity via az ad sp. You may need to create a service principal or wait for AAD replication."
}
else {
    $miSpObjId = $miServicePrincipal.objectId
    Write-Output "Managed identity service principal objectId: $miSpObjId"

    foreach ($perm in $permissions) {
        if (-not $appRoleMap.ContainsKey($perm)) { Write-Warning "Permission not found on Graph service principal: $perm"; continue }
        $roleId = $appRoleMap[$perm]
        $body = @{ principalId = $miSpObjId; resourceId = $graphSpObjectId; appRoleId = $roleId } | ConvertTo-Json
        Write-Output "Assigning app role $perm (id $roleId) to managed identity..."
        # Use az rest to call Graph; requires caller to be tenant admin
        try {
            $resp = az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miSpObjId/appRoleAssignedTo" --headers "Content-Type=application/json" --body "$body"
            Write-Output "Assigned $perm"
        }
        catch {
            Write-Warning "Failed to assign $perm. You likely need tenant admin consent. Error: $_"
        }
    }
}

Write-Output "Script complete. If app role assignment failed due to permissions, please perform admin consent:
- Sign-in as tenant administrator and visit: https://portal.azure.com/#blade/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/RegisteredApps
- Find the Automation managed identity or create an app registration and grant the application permissions listed in the script, then consent.

Alternative: create an App Registration and use its client id + secret as a service principal for Automation runbooks instead of MSI. The earlier deploy script supports that pattern."
