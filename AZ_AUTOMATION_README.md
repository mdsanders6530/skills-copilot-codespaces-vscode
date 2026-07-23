Azure Automation: AzIntuneAgent scaffold

Files:
- AzIntuneAgent.psm1  : PowerShell module scaffold (place into Automation Account Modules)
- Autopilot-Onboard.runbook.ps1 : Runbook to import Autopilot CSV and assign group/profile
- License-Assign.runbook.ps1   : Runbook to assign licenses from mapping JSON
- autopilot-sample.csv         : Example CSV (hardware hash placeholder)
- license-mapping.json         : Example user/group -> sku mapping

Quick deploy steps:
1. Create or use an Automation Account and enable System Assigned Managed Identity, or create an App Registration + credential.
2. Grant the Automation managed identity or App Registration the required Graph application permissions (tenant admin consent):
   - DeviceManagementManagedDevices.ReadWrite.All
   - DeviceManagementServiceConfig.ReadWrite.All
   - Group.ReadWrite.All
   - User.ReadWrite.All
   - Directory.ReadWrite.All (if needed)
3. Import required modules into Automation: Az.Accounts and Microsoft.Graph.PowerShell (or Microsoft.Graph.Authentication + DeviceManagement modules). Upload AzIntuneAgent.psm1 as a module.
4. Create runbooks (PowerShell 7), paste the .runbook.ps1 content, and publish.
5. Test with -WhatIf first in a test tenant or with controlled accounts.

Credential options and runbook behavior:
- Managed Identity (recommended for Automation): assign Graph app roles to the Automation Account's MSI; runbooks will authenticate with Connect-AzIntune -ManagedIdentity.
- App Registration (alternate): create an app registration, grant app permissions, store credential in an Automation credential asset named 'AzIntuneAgent-AppReg-Cred' (username = appId, password = clientSecret). Runbooks will use this credential to Connect-AzAccount -ServicePrincipal and Connect-MgGraph with client credentials.

Example runbook parameters (Autopilot-Onboard):
- AutopilotCsvPath: C:\\path\\to\\autopilot.csv
- TargetGroupName: "Autopilot-Devices"
- TenantId: (optional when using AppReg cred)
- WhatIf: switch to dry-run

Notes:
- The module contains scaffold functions; some TODOs remain (fine-grained Graph payloads). Implement and test in a staging tenant.
- Use Key Vault or Automation assets for secrets and rotate them regularly.

Testing the module and runbooks locally
- Run unit tests (Pester) from the repository root:
  - Install Pester (if missing): Install-Module -Name Pester -Scope CurrentUser
  - Run tests: Invoke-Pester -Path tests -Verbose
- The tests are lightweight and use -WhatIf modes where appropriate. They validate the runbook-critical behaviors (CSV parsing, WhatIf output, mapping handling). Update tests to mock Graph calls for integration tests against a real tenant.

One-click dry-run and Automation trigger
- Use test-dryrun-and-trigger-automation.ps1 to run local WhatIf checks and optionally trigger Automation published runbooks with WhatIf=true.
- Local-only dry-run: .\test-dryrun-and-trigger-automation.ps1
- Dry-run + Automation trigger (requires Az modules and signed-in user):
  .\test-dryrun-and-trigger-automation.ps1 -AutomationSubscriptionId <sub> -ResourceGroupName <rg> -AutomationAccountName <aa>

Notes:
- The script will start published runbooks with the WhatIf parameter set to true to avoid side-effects. Monitor job output in the portal or via Get-AzAutomationJob/Get-AzAutomationJobOutput.
- Ensure runbooks are published before triggering.
