Describe "Ensure-LicenseAssignment" {
    It "prints WhatIf lines for users and groups" {
        $mapping = @{
            users = @(@{ userPrincipalName = 'bob@contoso.com'; skuPartNumber = 'M365_E3' })
            groups = @(@{ groupName = 'Engineering'; skuPartNumber = 'INTUNE_A' })
        }
        $tmp = Join-Path $env:TEMP "mapping_test.json"
        ($mapping | ConvertTo-Json -Depth 5) | Out-File -FilePath $tmp -Encoding utf8

        $modulePath = (Resolve-Path "..\..\AzIntuneAgent.psm1").Path
        Import-Module $modulePath -Force -ErrorAction Stop

        $out = Ensure-LicenseAssignment -MappingPath $tmp -WhatIf
        $out | Should -Contain "[WhatIf] Assign SKU M365_E3 to user bob@contoso.com"
        $out | Should -Contain "[WhatIf] Assign SKU INTUNE_A to group Engineering"
    }
}
