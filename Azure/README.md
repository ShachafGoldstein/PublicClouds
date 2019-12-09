## Snippets
* **AAD**
  * Give SP id permission on billing account (ea account)
    ```
    az role assignment create --assignee-object-id "SP_ID"  --role "owner" --scope "/providers/Microsoft.Billing/enrollmentAccounts/USER_ID"
    ```
* **EA**
  * Get all account owners of subscriptions
    ```
    Get-azsubscription | %{$_.name; Get-AzRoleAssignment -IncludeClassicAdministrators -RoleDefinitionName  AccountAdministrator -Scope "/subscriptions/$($_.id)"}
    ```
* **ROLES**
  * Owner without transfer
    ```
    az login
    # Create a role
    $obj = new-object Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition
    $obj.Name = "nontransfer owner"
    $obj.Description = "Owner except sub management permissions"
    $obj.Actions = @("*")
    $obj.NotActions = @("Microsoft.Management/managementGroups/subscriptions/*")

    # Add role to all subs
    $subs = az account list | convertfrom-json
    $obj = get-AzRoleDefinition -Name "nontransfer owner"
    $subs.id | %{$obj.AssignableScopes += ,"/subscriptions/$_"}
    Set-AzRoleDefinition -Role $obj

    # Manually add sub role
    $obj = get-AzRoleDefinition -Name "nontransfer owner"
    $obj.AssignableScopes += ,"/subscriptions/$(read-host)"
    Set-AzRoleDefinition -Role $obj

    # Add role to MGs
    function recursegetnamesformgs
    {
        [Cmdletbinding()]
        param(
            $current
        )
        
        $current.name;
        $a = $current.Children | ? {$_.type -eq "/providers/Microsoft.Management/managementGroups"}
        if ($a)
        {        
            $a | % {recursegetnamesformgs -current $_}
        }
    }

    $mgs =  Get-AzManagementGroup -Recurse -GroupName "MG_NAME" -Expand 
    $obj = get-AzRoleDefinition -Name "nontransfer owner"
    recursegetnamesformgs -current $mgs | % {$obj.AssignableScopes += ,"/providers/Microsoft.Management/managementGroups/$_"}
    Set-AzRoleDefinition -Role $obj

    # Replace owners on subs
    $subs.id | % {
        $sub = $_
        Write-Host "ON $sub" -BackgroundColor Magenta
        $acl = $null
        $acl = az role assignment list --subscription $sub  --role "owner" | ConvertFrom-Json
        $acl | % {
            Write-Host "Adding role to $($_.principalName)" -BackgroundColor Green
            az role assignment create --subscription $sub --role "nontransfer owner" --assignee $_.principalId
            Write-Host "Removing owner to $($_.principalName)" -BackgroundColor Red
            #Start-Sleep -Seconds 20
            az role assignment delete --subscription $sub --role "owner" --assignee $_.principalId
        }    
     }

    # Replace owners on MGs
    recursegetnamesformgs -current $mgs | % {
        $mg = $_
        Write-Host "ON $mg" -BackgroundColor Magenta
        $acl = $null
        $acl = az role assignment list --scope "/providers/Microsoft.Management/managementGroups/$mg"  --role "owner" | ConvertFrom-Json

        $acl | % {
            if($_.principalName -ilike "*cto*")
            {
                Write-Host "Adding role to $($_.principalName)" -BackgroundColor Green
                az role assignment create --scope "/providers/Microsoft.Management/managementGroups/$mg" --role "nontransfer owner" --assignee $_.principalId
                Write-Host "Removing owner to $($_.principalName)" -BackgroundColor Red
                az role assignment delete --scope "/providers/Microsoft.Management/managementGroups/$mg" --role "owner" --assignee $_.principalId
            }
        }
     }
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
