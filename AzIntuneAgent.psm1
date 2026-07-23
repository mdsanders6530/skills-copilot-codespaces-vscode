# AzIntuneAgent PowerShell module (scaffold)
# Requires: PowerShell 7+, Microsoft.Graph.PowerShell, Az.Accounts

function Connect-AzIntune {
    [CmdletBinding()]
    param(
        [switch]$ManagedIdentity,
        [string]$TenantId,
        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential
    )
    begin {
        Write-Verbose "Authenticating to Azure / Microsoft Graph..."
    }
    process {
        try {
            if ($ManagedIdentity) {
                # Azure Automation: use system-assigned managed identity
                Connect-AzAccount -Identity | Out-Null
                Connect-MgGraph -Identity -ErrorAction Stop
                Write-Verbose "Connected via Managed Identity."
            }
            elseif ($Credential) {
                # Interactive/service account path (not recommended for Automation)
                Connect-AzAccount -Credential $Credential -Tenant $TenantId | Out-Null
                Connect-MgGraph -TenantId $TenantId -Credential $Credential -ErrorAction Stop
            }
            else {
                # Fallback to interactive
                Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
                Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All","Group.ReadWrite.All","User.ReadWrite.All" -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Authentication failed: $_"
            throw
        }
    }
}

function New-AutopilotImportFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CsvPath,
        [string]$ImportDescription = "Imported by AzIntuneAgent",
        [switch]$WhatIf
    )
    begin {
        Write-Verbose "Preparing Autopilot import from: $CsvPath"
        if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
        $csv = Import-Csv -Path $CsvPath
    }
    process {
        foreach ($row in $csv) {
            # Example: row should include "HardwareHash" and "SerialNumber" and optional AssignedUser
            $hardwareHash = $row.HardwareHash
            $serial = $row.SerialNumber
            $assignedUser = $row.AssignedUser
            if ($WhatIf) {
                Write-Output "[WhatIf] Would import device Serial=$serial, HashLength=$($hardwareHash.Length)"
                continue
            }

            # Implement actual Graph import using Invoke-MgGraphRequest so the runbook works with Microsoft.Graph.PowerShell
            Write-Verbose "Importing Autopilot device for Serial: $serial"

            try {
                # Normalize hardware hash: detect hex (pairs of hex chars) and convert to base64 if needed
                $hw = $hardwareHash -as [string]
                if ($hw -match '^[0-9A-Fa-f]+$' -and ($hw.Length % 2) -eq 0) {
                    $bytes = for ($i = 0; $i -lt $hw.Length; $i += 2) { [Convert]::ToByte($hw.Substring($i,2), 16) }
                    $hwBase64 = [Convert]::ToBase64String($bytes)
                }
                else {
                    # Assume provided already base64 or binary string; attempt to use as-is
                    $hwBase64 = $hw
                }

                $body = @{
                    serialNumber = $serial
                    hardwareIdentifier = $hwBase64
                    displayName = $serial
                }

                if ($assignedUser) { $body.assignedUserPrincipalName = $assignedUser }
                if ($ImportDescription) { $body.importedDeviceIdentifier = $ImportDescription }

                $json = $body | ConvertTo-Json -Depth 5

                # POST to the importedWindowsAutopilotDeviceIdentities endpoint
                $resp = Invoke-MgGraphRequest -Method POST -Uri '/deviceManagement/importedWindowsAutopilotDeviceIdentities' -Body $json -ContentType 'application/json' -ErrorAction Stop
                Write-Verbose "Imported Autopilot device: $serial; response status ok"
            }
            catch {
                Write-Warning "Failed to import $serial: $($_.Exception.Message)"
            }
        }
    }
}

function Ensure-IntuneGroupAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$GroupName,
        [Parameter(Mandatory=$true)] [string]$ProfileName,
        [switch]$WhatIf
    )
    begin {
        Write-Verbose "Ensuring group '$GroupName' exists and is assigned profile '$ProfileName'"
    }
    process {
        if ($WhatIf) { Write-Output "[WhatIf] Ensure group $GroupName and assign profile $ProfileName"; return }
        # Check for group, create if missing
        $group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Verbose "Creating Azure AD group: $GroupName"
            $group = New-MgGroup -DisplayName $GroupName -MailEnabled:$false -MailNickname ($GroupName -replace '\\s','') -SecurityEnabled:$true
        }

        # TODO: Find profile and assign; Graph calls to deviceManagement/deviceConfigurations or autopilotProfiles
        Write-Verbose "(scaffold) Assigning profile '$ProfileName' to group '$GroupName'"
    }
}

function Ensure-LicenseAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$MappingPath,
        [switch]$WhatIf
    )
    begin {
        if (-not (Test-Path $MappingPath)) { throw "Mapping file not found: $MappingPath" }
        $mapping = Get-Content $MappingPath -Raw | ConvertFrom-Json

        # Cache subscribed SKUs (skuPartNumber -> skuId)
        try {
            $skusResp = Invoke-MgGraphRequest -Method GET -Uri '/subscribedSkus' -ErrorAction Stop
            $skuMap = @{}
            foreach ($s in ($skusResp.value)) { $skuMap[$s.skuPartNumber] = $s.skuId }
        }
        catch {
            throw "Failed to retrieve subscribed SKUs: $($_.Exception.Message)"
        }
    }
    process {
        # Helper to assign license to a user by id
        function Assign-LicenseToUserId([string]$userId, [string]$skuId) {
            $body = @{ addLicenses = @(@{ skuId = $skuId }); removeLicenses = @() }
            $json = $body | ConvertTo-Json -Depth 5
            try {
                Invoke-MgGraphRequest -Method POST -Uri "/users/$userId/assignLicense" -Body $json -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Write-Verbose "Assigned SKU $skuId to user id $userId"
            }
            catch {
                Write-Warning "Failed to assign SKU $skuId to user id $userId: $($_.Exception.Message)"
            }
        }

        foreach ($u in $mapping.users) {
            $skuPart = $u.skuPartNumber
            $upn = $u.userPrincipalName
            if (-not $skuMap.ContainsKey($skuPart)) { Write-Warning "SKU not found in tenant: $skuPart"; continue }
            $skuId = $skuMap[$skuPart]

            if ($WhatIf) { Write-Output "[WhatIf] Assign SKU $skuPart (id $skuId) to user $upn"; continue }

            try {
                $encodedUpn = [System.Uri]::EscapeDataString($upn)
                $userResp = Invoke-MgGraphRequest -Method GET -Uri "/users/$encodedUpn`?`$select=id,userPrincipalName" -ErrorAction Stop
                $userId = $userResp.id
                if (-not $userId) { Write-Warning "User not found: $upn"; continue }
                Assign-LicenseToUserId -userId $userId -skuId $skuId
            }
            catch {
                Write-Warning "Failed to resolve or assign license to user $upn: $($_.Exception.Message)"
            }
        }

        foreach ($g in $mapping.groups) {
            $skuPart = $g.skuPartNumber
            $groupName = $g.groupName
            if (-not $skuMap.ContainsKey($skuPart)) { Write-Warning "SKU not found in tenant: $skuPart"; continue }
            $skuId = $skuMap[$skuPart]

            if ($WhatIf) { Write-Output "[WhatIf] Assign SKU $skuPart (id $skuId) to all members of group $groupName"; continue }

            try {
                $filter = "displayName eq '$groupName'"
                $grpResp = Invoke-MgGraphRequest -Method GET -Uri "/groups`?\$filter=$([System.Uri]::EscapeDataString($filter))&`$select=id,displayName" -ErrorAction Stop
                $grp = $grpResp.value | Select-Object -First 1
                if (-not $grp) { Write-Warning "Group not found: $groupName"; continue }
                $groupId = $grp.id

                # Enumerate group members (users) and assign per-user (group-based licensing can be used but often requires special tenant config)
                $membersResp = Invoke-MgGraphRequest -Method GET -Uri "/groups/$groupId/members`?\$select=id,userPrincipalName" -ErrorAction Stop
                foreach ($m in ($membersResp.value)) {
                    if ($m.'@odata.type' -and $m.'@odata.type' -ne '#microsoft.graph.user') { continue }
                    $memberId = $m.id
                    Assign-LicenseToUserId -userId $memberId -skuId $skuId
                }
            }
            catch {
                Write-Warning "Failed to assign licenses for group $groupName: $($_.Exception.Message)"
            }
        }
    }
}

function Test-DeviceHybridJoinStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$DeviceId
    )
    begin { }
    process {
        Write-Verbose "Checking hybrid join status for device: $DeviceId"
        # Placeholder: query device object in Graph and check deviceTrustType/hybrid attributes
        # Example: Get-MgDevice -DeviceId $DeviceId | Select-Object deviceTrustType, displayName
        Write-Output @{DeviceId=$DeviceId; HybridJoinStatus = 'Unknown (scaffold)'}
    }
}

Export-ModuleMember -Function *
