## Snippets
* **AAD**
* **EA**
  * Get all account owners of subscriptions
    ```
    Get-azsubscription | %{$_.name; Get-AzRoleAssignment -IncludeClassicAdministrators -RoleDefinitionName  AccountAdministrator -Scope "/subscriptions/$($_.id)"}
    ```
## Runbooks
* **ApplicationDeveloperRoleAssignment.ps1**
  * Runbook to Assign AAD role to a given user via webhook
  * **Parameters**
    * roleID - The role ID to assign to (default is Application developer - 2a1bd6b6-9c97-4de4-82a3-c37568119576)
* **MG_IAM_Control.ps1**
  * Runbook to keep the Management Group hierarchy owner permissions in control on a schedule
  * **Parameters**
    * role - The role name to handle (default is owner)
* **ManagementGroupTreeManagement.ps1**
  * Runbook to keep the Management Group hierarchy in check on a schedule (subscription names, existance and parents) 
  * **Variables**
    * EmailRestEndpoint - Email REST url to send email through
    * SubscriptionList - Where to get and set teh list of subscription each time
  * _Credit_ - https://github.com/martin77s/Azure
* **SubscriptionCreation.ps1**
  * Runbook to create subscription with an owner and a budget via webhook
  * **Variables**
    * EmailRestEndpoint - Email REST url to send email through
