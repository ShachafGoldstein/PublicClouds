#Requires -Modules Az.Resources

[CmdletBinding]
<#
.SYNOPSIS
Export Azure AD application object to JSON

.DESCRIPTION
Export Azure AD applications to JSON including key list, service principals and their role assignments.
Can work as part of a pipeline with application Id or PSADApplication object

.PARAMETER ApplicationID
Required. Application ID to export

.PARAMETER Application
Required. Application PAADApplication object to export

.PARAMETER TenantID
Optional. Tenant ID to connect to.
If used, will check for existing context before connecting to a new one

.PARAMETER Scopes
Optional. Scopes to get role assignment for.

.EXAMPLE
C:\PS> Get-AzADApplication -DisplayName "MyApp" | Export-AzAdApplication -Verbose -TenantID '00000000-0000-0000-0000-000000000000' | Out-File MyApp.json
Export the MyApp application to JSON and save to a file

C:\PS> Get-AzADApplication | Export-AzAdApplication -Verbose -TenantID '00000000-0000-0000-0000-000000000000' | Out-File Apps.json
Export all applications to JSON and save to a file

.NOTES
    Author: Shachaf Goldstein (shgoldst@microsoft.com)
    Date:   April 18, 2020
#>
function Export-azAdApplication {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Required. Application ID to export", 
            ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true,
            ParameterSetName = "ID")]
        [Alias("appId", "ID")]
        [GUID]$ApplicationID,

        [Parameter(Mandatory = $false, HelpMessage = "Required. Application PAADApplication object to export", 
            ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true,
            ParameterSetName = "Object")]
        [Microsoft.Azure.Commands.ActiveDirectory.PSADApplication]$Application,

        [Parameter(HelpMessage = "Optional. Tenant ID to connect to",
            ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [GUID]$TenantID = [GUID]::Empty,

        [Parameter(HelpMessage = "Optional. Scopes to get role assignment for")]
        [String[]]$Scopes = @('/')
    )

    begin {
        $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

        try {
            #Install-package System.IdentityModel.Tokens.Jwt -Force -RequiredVersion 6.5

            Write-Verbose "Getting available context list"
            $context = Get-AzContext -ListAvailable

            if ($null -eq $context) {
                Write-Verbose "No available context found"
                if ([GUID]::Empty -ne $TenantID) {
                    Write-Verbose "Connecting to Azure with tenantId $TenantID"
                    Connect-AzAccount -Tenant $TenantID > $nul
                }
                else {
                    Write-Verbose "Connecting to Azure"
                    Connect-AzAccount > $nul
                }
            }
            else
            {
                $context = $context | Where-Object { $_.Tenant.TenantId -eq $TenantID } | Select-Object -Unique

                if ($context) 
                {
                    Write-Verbose "Found available context for tenantid $TenantID, switching."
                    $context | Select-AzContext > $nul
                }
                else {
                    Write-Verbose "Found available context but none for tenantid $TenantID"
                    if ([GUID]::Empty -ne $TenantID) {
                        Write-Verbose "Connecting to Azure with tenantId $TenantID"
                        Connect-AzAccount -Tenant $TenantID > $nul
                    }
                    else {
                        Write-Verbose "Connecting to Azure"
                        Connect-AzAccount > $nul
                    }
                }
            }

            Write-Verbose "Updating context and retrieving tokens"
            $context = Get-AzContext
            Write-Verbose $context.Name
            $tokenGraph = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://graph.microsoft.com").AccessToken
            Write-Verbose "Graph: $tokenGraph"
            $tokenMng = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com").AccessToken
            Write-Verbose "Management: $tokenMng"
        }
        catch {
            Write-Verbose "$($_.Exception)"
            Write-Error "Couldn't connect to Azure! - $($_.Exception.Message)"
            exit 1
        }
    }

    Process {
        if ($null -ne $Application) {
            Write-Verbose "Extracting Application Id from Application object"
            $ApplicationID = $Application.ApplicationId
        }

        Write-Verbose "Getting application JSON for $ApplicationID"
        $response = Invoke-WebRequest -UseBasicParsing -Uri "https://graph.microsoft.com/beta/applications?filter=appId eq '$ApplicationID'" -Headers @{"Authorization"="Bearer $tokenGraph";"Content-Type"="Application/JSON"} -Method Get

        if($response.StatusCode -ne 200)
        {
            throw [Exception]::new("Request failed for $ApplicationID - status code not 200")
        }
        else
        {
            $ApplicationJSON = ($response.Content | ConvertFrom-Json).value

            Write-Verbose ("Found application JSON for {0}" -f $ApplicationJSON.DisplayName)
            $resultObject = [PSCustomObject]@{
                "ApplicationJSON" = $ApplicationJSON
                "ServicePrincipals" = @()
            }

            Write-Verbose ("Getting service principal JSON for {0}" -f $ApplicationJSON.DisplayName)
            $response = Invoke-WebRequest -UseBasicParsing -Uri "https://graph.microsoft.com/beta/serviceprincipals?filter=appId eq '$ApplicationID'" -Headers @{"Authorization"="Bearer $tokenGraph";"Content-Type"="Application/JSON"} -Method Get

            if($response.StatusCode -ne 200)
            {
                throw [Exception]::new("Request failed for SPsfor $ApplicationID - status code not 200")
            }
            else
            {
                $sp = $response.Content | ConvertFrom-Json
                
                $sp | ForEach-Object {
                    $spObject = [PSCustomObject]@{
                                    "ServicePrincipal" = $_.value
                                    "RoleAssignments"  = @()
                                    "AADAssignments"  = @()
                                }
                    
                    if($spObject.ServicePrincipal)
                    {
                        $Scopes | ForEach-Object {
                            Write-Verbose "Getting assignments for service principal $($_.DisplayName) on scope $_"
                            $response = Invoke-WebRequest -UseBasicParsing -Uri "https://management.azure.com/$_/providers/Microsoft.Authorization/roleAssignments?`$filter=principalId eq '$($spObject.ServicePrincipal.Id)'&api-version=2015-07-01" -Headers @{"Authorization"="Bearer $tokenMng";"Content-Type"="Application/JSON"} -Method Get

                            if($response.StatusCode -ne 200)
                            {
                                throw [Exception]::new("Request failed for SP $($spObject.ServicePrincipal.Id) and scope $_ - status code not 200")
                            }
                            else
                            {                        
                                Write-Verbose "Adding assignments JSON for scope $_ to result"
                                $spObject.RoleAssignments += ($response.Content | ConvertFrom-Json).value
                            }
                        }

                        Write-Verbose "Getting AAD assignments for service principal $($_.DisplayName)"
                        $response = Invoke-WebRequest -UseBasicParsing -Uri "https://graph.microsoft.com/beta/serviceprincipals/$($spObject.ServicePrincipal.Id)/getMemberObjects" -Headers @{"Authorization"="Bearer $tokenGraph";"Content-Type"="Application/JSON"} -Method Post -Body '{"securityEnabledOnly": false}'

                        if($response.StatusCode -ne 200)
                        {
                            throw [Exception]::new("Request failed for SP $($spObject.ServicePrincipal.Id) and AAD Roles - status code not 200")
                        }
                        else
                        {                        
                            Write-Verbose "Adding AAD assignments JSON to result"
                            $spObject.AADAssignments += ($response.Content | ConvertFrom-Json).value
                        }
                    }

                    Write-Verbose "Adding service principal and assignments information to result"
                    $resultObject.ServicePrincipals += $spObject
                }
            }

            Write-Verbose ("JSON:`n" + ($resultObject | ConvertTo-Json -Depth 10))
            Write-Verbose ("Returning OBJECT for {0}" -f $Application.DisplayName)
            $resultObject
        }
    }
}