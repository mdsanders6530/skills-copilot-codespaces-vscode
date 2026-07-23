Describe "New-AutopilotImportFromCsv" {
    It "writes WhatIf message for CSV import" {
        $csv = @"SerialNumber,HardwareHash,AssignedUser
1234,ABCDEF012345,alice@contoso.com
"@
        $tmp = Join-Path $env:TEMP "ap_test.csv"
        $csv | Out-File -FilePath $tmp -Encoding utf8

        # Import the module from repo root
        $modulePath = (Resolve-Path "..\..\AzIntuneAgent.psm1").Path
        Import-Module $modulePath -Force -ErrorAction Stop

        $out = New-AutopilotImportFromCsv -CsvPath $tmp -WhatIf
        $out | Should -Contain "[WhatIf] Would import device Serial=1234, HashLength=12"
    }
}
