param
(
  [Parameter (Mandatory= $false)]
  [Object] $WEBHOOKDATA
)

function Send-Mail
{
    param($to,$sbjct,$msg=" ")

    $bdy = @"
    {
        "TO":"$to",
        "Subject":"$sbjct",
        "Body":"$msg"
    }
"@

    Invoke-RestMethod -ContentType 'application/json' -Method post -URI (Get-AutomationVariable -Name 'EmailRestEndpoint') -Body "$bdy"
}


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

    $prmtrs = ($WEBHOOKDATA.RequestBody | ConvertFrom-Json)

    Write-Output ('subsciption name: {0}' -f $prmtrs.subname)
    Write-Output ('subsciption offer type: {0}' -f $prmtrs.offerType)
    Write-Output ('subsciption owner: {0}' -f $prmtrs.owner)
    Write-Output ('subsciption monthly budget: {0}' -f $prmtrs.monthlybudget)

    # Fail on Existing SUB
    $sub = Get-AzSubscription -SubscriptionName "$($prmtrs.subname)" 2> $null
    if ($null -ne $sub)
    {
        throw [System.Exception]::new("Subscription already exists")
        Send-Mail -To $prmtrs.owner -sbjct "Subscription already exists" -msg ("Subscription {0} already exists!" -f $prmtrs.subname)
    }
    else
    {
        Write-Output "Subscription not found - Good!"
    }

    # Get enrollment account
    $ea = Get-AzEnrollmentAccount | ? { $prmtrs.subname -ilike "*$($_.principalname.replace('cto-','').replace('@CONTOSO.COM',''))*"}
    if ($null -eq $ea)
    {
        throw [System.Exception]::new("No Enrollment Accounts found")
    }
    else
    {
        Write-Output ('Enrollment Account: {0}' -f $ea.PrincipalName)
    }

    # Create SUB with name, type and owner
    New-AzSubscription -EnrollmentAccountObjectId $ea.ObjectId -Name "$($prmtrs.subname)" -OfferType "$($prmtrs.offerType)" -OwnerSignInName "$($prmtrs.owner)"
    
    Select-AzSubscription (get-azsubscription -SubscriptionName  "$nme")
    New-AzConsumptionBudget -Name "$nme-budget" -Amount 10 -Category 'cost' -TimeGrain 'Monthly' -StartDate (get-date -Format "yyyy-MM-01")
    
    Send-Mail -To $prmtrs.owner -sbjct "Subscription created Successfully" -msg ("Subscription {0} was created with a budget of {1}. https://portal.azure.com" -f $prmtrs.subname,$prmtrs.monthlybudget)

} catch {
    #Write-Output ('Error: {0}' -f $_.Exception.Message)
    Write-Error $_
    Send-Mail -To $prmtrs.owner -sbjct "Error while creating the Subscription" -msg "Please contact an admin."
}

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
