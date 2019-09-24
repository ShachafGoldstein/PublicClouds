Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {
    $buffer = [System.Text.StringBuilder]::new()
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
    $buffer.AppendLine(('Working on tenant: {0}' -f $tenantId))
    Write-Output ('Working with ApplicationId: {0}' -f $servicePrincipalConnection.ApplicationId)
    $buffer.AppendLine(('Working with ApplicationId: {0}' -f $servicePrincipalConnection.ApplicationId))

    $context = Get-AzContext
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList $azProfile
    $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)

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

    function Select-MG {
        param($sub, $mgs)
        Write-Verbose ("Checking best match for: " + $sub) -Verbose
        $subParts = $sub -split '-'
        $targetMg = $mgs | ForEach-Object {
            for ($i = 0; $i -lt 3; $i++) { 
                $th = ($subParts[0..$i] -join '-')
                Write-Verbose ("? {0}" -f $th) -Verbose
                if($_.DisplayName -match $th) {
                    Write-Verbose ("? matched {0}" -f $_.DisplayName) -Verbose
                    New-Object PSObject -Property @{
                        Segments        = $i+1
                        Subscription    = $sub
                        ManagementGroup = $_
                    }
                }
            }
        } | Sort-Object -Descending -Property Segments | Select-Object -First 1
        Write-Verbose ("= {0}" -f $targetMg.ManagementGroup) -Verbose
        $targetMg.ManagementGroup
    }

    function Send-Mail
    {
        param($sbjct,$msg=" ")
        #$secpasswd = ConvertTo-SecureString (Get-AutomationVariable -Name 'NotificationEmailUserPassword') -AsPlainText -Force
        #$cred = New-Object System.Management.Automation.PSCredential ((Get-AutomationVariable -Name 'NotificationEmailUser'), $secpasswd)
        #Send-MailMessage -From (Get-AutomationVariable -Name 'NotificationEmailSource') `
        #                -To (Get-AutomationVariable -Name 'NotificationEmailTarget') `
        #                -Subject $sbjct `
        #                -SmtpServer (Get-AutomationVariable -Name 'NotificationEmailServer') `
        #                -UseSsl `
        #                -Body "$msg" `
        #                -Credential ($cred)
        $bdy = @"
        {
            "TO":"$(Get-AutomationVariable -Name 'NotificationEmailTarget')",
            "Subject":"$sbjct",
            "Body":"$msg"
        }
"@

        Invoke-RestMethod -ContentType 'application/json' -Method post -URI (Get-AutomationVariable -Name 'EmailRestEndpoint') -Body "$bdy"
    }

    $mgmtGroups = @(Get-MGRecurse -MG $root.Name)
    Write-Output ('Management group(s): {0}' -f $mgmtGroups.Count)
    $buffer.AppendLine(('Management group(s): {0}' -f $mgmtGroups.Count))

    $subs = @(Get-AzSubscription -TenantId $tenantId)
    Write-Output ('Subscription(s): {0}' -f $subs.Count)
    $buffer.AppendLine(('Subscription(s): {0}' -f $subs.Count))

    $pattern = '^(\w+)-(\w+)-(.*)-(DE|DV|DEV|TS|TST|TEST|QA|PR|PRD|PROD|NP|PD|PP)-(\d{3})$'
    $subs | Where-Object { $_.Name -notmatch $pattern } | ForEach-Object {
            Write-Warning ('Subscription {0} ({1}) does not match the pattern' -f $_.Name, $_.Id)
            #Send-Mail -sbjct ('Subscription {0} ({1}) does not match the pattern' -f $_.Name, $_.Id)
            $buffer.AppendLine(('Subscription {0} ({1}) does not match the pattern' -f $_.Name, $_.Id))
    }

    $orphanSubscriptions = @($root.Children | Where-Object { $_.Type -eq '/subscriptions' })
    Write-Output ('Orphan subscription(s): {0}' -f $orphanSubscriptions.Count)
    $buffer.AppendLine(('Orphan subscription(s): {0}' -f $orphanSubscriptions.Count))

    foreach($orphan in $orphanSubscriptions) {
        $targetManagementGroup = Select-MG -sub $orphan.DisplayName -mgs $mgmtGroups
        if($targetManagementGroup) {
            Write-Output ('Moving subscription [{0}] to group [{1}]' -f $orphan.DisplayName, $targetManagementGroup.DisplayName)
            $buffer.AppendLine(('Moving subscription [{0}] to group [{1}]' -f $orphan.DisplayName, $targetManagementGroup.DisplayName))
            New-AzManagementGroupSubscription -GroupName $targetManagementGroup.Name -SubscriptionId $orphan.Name
        } else {
            Write-Output ('Could not find a matching management group for subscription: {0}' -f $orphan.DisplayName)
            $buffer.AppendLine(('Could not find a matching management group for subscription: {0}' -f $orphan.DisplayName))
        }
    }
    #endregion

    #region Searching for missing subscriptions
    Write-Output 'Getting previous run subscriptions list'
    $buffer.AppendLine('Getting previous run subscriptions list')
    $previousSubscriptions = Get-AutomationVariable -Name 'SubscriptionList'

    $currentSubscriptions = $subs | Select-Object Name, Id
    if($null -eq $previousSubscriptions) {
        Write-Output 'Previous subscriptions list was empty!'
        $buffer.AppendLine('Previous subscriptions list was empty!')
        $previousSubscriptions = $currentSubscriptions
    } else {
        Write-Output ('Previous subscriptions: {0}' -f $previousSubscriptions.Count)
        $buffer.AppendLine(('Previous subscriptions: {0}' -f $previousSubscriptions.Count))
    }

    Write-Output 'Comparing subscriptions list to current status'
    $buffer.AppendLine('Comparing subscriptions list to current status')
    $missing = @($previousSubscriptions | Where-Object { $_.Id -notin ($currentSubscriptions).Id })
    if($missing.Count -gt 0) {
        # To do: Add logic to send email / create alert
        Write-Warning 'Subscription(s) missing! Maybe deleted or moved to a different tenant'
        $missing | ForEach-Object { 
            Write-Warning ('{0} = {1}' -f $_.Id, $_.Name)
            $buffer.AppendLine(('Subscription missing: {0} = {1}' -f $_.Id, $_.Name))
            #Send-Mail -sbjct ('Subscription missing: {0} = {1}' -f $_.Id, $_.Name)
        }
    } else {
        Write-Output 'No subscriptions missing :-)'
        $buffer.AppendLine('No subscriptions missing :-)')
    } 

    Write-Output 'Updating the subscriptions list variable'
    $buffer.AppendLine('Updating the subscriptions list variable')
    $null = Set-AutomationVariable -Name 'SubscriptionList' -Encrypted $false -Value $currentSubscriptions
    #endregion

    Send-Mail -sbjct "MGTreeSortRunbook Output" -msg $buffer.ToString()
} catch {
    #Write-Output ('Error: {0}' -f $_.Exception.Message)
    Write-Output $_
}

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
