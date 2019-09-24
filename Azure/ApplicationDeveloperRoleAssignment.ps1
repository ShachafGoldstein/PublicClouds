Param
(
  [Parameter (Mandatory= $false)]
  [String] $roleID = "2a1bd6b6-9c97-4de4-82a3-c37568119576",
  [Parameter (Mandatory= $false)]
  [Object] $WEBHOOKDATA
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

    Add-AzureADDirectoryRoleMember -ObjectId $roleID -RefObjectId (Get-AzADUser -UserPrincipalName "$($WEBHOOKDATA.RequestBody)").ID

} catch {
    #Write-Output ('Error: {0}' -f $_.Exception.Message)
    Write-Output $_
}

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
