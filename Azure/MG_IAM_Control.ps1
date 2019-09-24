Param
(
  [Parameter (Mandatory= $false)]
  [String] $role = "Owner"
)

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {

    $connectionName = 'AzureRunAsConnection'

    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
		
    $connection = Connect-AzureAD -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
    
    $context = Connect-AzAccount -ServicePrincipal -Tenant $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint

    $tenantId = $servicePrincipalConnection.TenantId
    Write-Output ('Working on tenant: {0}' -f $tenantId)
    Write-Output ('Working with ApplicationId: {0}' -f $servicePrincipalConnection.ApplicationId)

  #  $context = Get-AzContext
  #  $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
  #  $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList $azProfile
  #  $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)

    #region Subscriptions to Management Groups
    $root = Get-AzManagementGroup -Expand -GroupName $tenantId

    function Get-MGRecurse {
        param($MG)
        (Get-AzManagementGroup -Expand -GroupName $MG).Children | 
            Where-Object { $_.Type -eq '/providers/Microsoft.Management/managementGroups' } | ForEach-Object {
                $_
                Get-MGRecurse -MG $_.Name
        }
    }
    
    $mgmtGroups = @(Get-MGRecurse -MG $root.Name)
    Write-Output ('Management group(s): {0}' -f $mgmtGroups.Count)

    foreach($mg in ($mgmtGroups | ? {$_.name -inotlike '*root*'}))
    {
        $grpName = "cloud-$($mg.DisplayName.Split(' ')[0])-Admins"
        $admgrp = Get-AzADGroup -DisplayName $grpName
        $admgrpFlag = $false
        
        Write-Verbose ("Admin group for {0} is {1}" -f $mg.DisplayName,$admgrp.DisplayName)
        
        if ($null -eq $admgrp)
        {
            Write-Output ("Creating Missing admins group '{0}' for {1}" -f $grpName,$mg.DisplayName)
            $newGrp = New-AzAdGroup -DisplayName $grpName -MailNickname $grpName

            Write-Output "Add parent group cloud-{0}-Admins to newly created group" -f $mg.ParentDisplayName.Split(' ')[0]
            Add-AzADGroupMember -MemberObjectId $newGrp.Id -TargetGroupObjectId $mg.ParentId
        }

        $asses = Get-AzRoleAssignment -Scope $mg.id -RoleDefinitionName "$role" | ? {$_.scope -eq $mg.id}

        if ($asses)
        {
            foreach($ass in $asses)
            { 
                if($ass.DisplayName -ne $admgrp.DisplayName)
                {
                    Write-Output ("Removing {0} as $role from {1}" -f $ass.DisplayName,$mg.DisplayName)
                    Remove-AzRoleAssignment -InputObject $ass
                }
                else
                {
                    Write-Output ("Admin group {0} has $role on {1}" -f $ass.DisplayName,$mg.DisplayName)
                    $admgrpFlag = $true
                }
            }
        }
        
        if(-not $admgrpFlag)
        {
            Write-Output "Adding admins group $role role ssignment for $($mg.DisplayName)"
            New-AzRoleAssignment -Scope $mg.id -RoleDefinitionName "$role" -ObjectId $admgrp.Id
        }
    }


} catch {
    #Write-Output ('Error: {0}' -f $_.Exception.Message)
    Write-Output $_
}

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
