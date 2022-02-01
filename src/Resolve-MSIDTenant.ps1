#Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="1.9.2" }
<#
.SYNOPSIS
    Resolve TenantId or DomainName to an Azure AD Tenant
.DESCRIPTION
    Resolves TenantID or DomainName values to an Azure AD tenant to retrieve metadata about the tenant when resolved
.EXAMPLE
    Resolve-MSIDTenant -Tenant example.com
.EXAMPLE
    Resolve-MSIDTenant -TenantId c19543f3-d36c-435c-ad33-18f11b8c1a15
.EXAMPLE
    Resolve-MSIDTenant -Tenant "example.com","c19543f3-d36c-435c-ad33-18f11b8c1a15"
.EXAMPLE
    $DomainList = get-content .\DomainList.txt
    Resolve-MSIDTenant -Tenant $DomainList
.NOTES
    -  Azure AD OIDC Metadata endpoint - https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-protocols-oidc#fetch-the-openid-connect-metadata-document
    - A Result of NotFound does not mean that the tenant does not exist at all, but it might be in a different cloud environment.   Additional queries to other environments may result in it being found.

#>
function Resolve-MSIDTenant {
    [CmdletBinding(DefaultParameterSetName = 'Parameter Set 1',
        SupportsShouldProcess = $false,
        PositionalBinding = $false,
        HelpUri = 'http://www.microsoft.com/',
        ConfirmImpact = 'Medium')]
    [Alias()]
    [OutputType([String])]
    Param (
        # The TenantId in GUID Format or TenantDomainName in DNS Name format to attempt to resolve to Azure AD tenant
        [Parameter(Mandatory = $true,
            Position = 0,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false, 
            ParameterSetName = 'Parameter Set 1')]
        [ValidateNotNull()]
        [ValidateNotNullOrEmpty()]
        [Alias("TenantId")]
        [Alias("DomainName")]
        [string[]]
        $TenantValue,
        # Environment to Resolve Azure AD Tenant In (Global, USGov, China, USGovDoD, Germany)
        [Parameter(Mandatory = $false,
            Position = 1,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false, 
            ParameterSetName = 'Parameter Set 1')]
        [ValidateSet("Global", "USGov", "China", "USGovDoD", "Germany")]
        [string]
        $Environment = "Global",
        # Include resolving the value to an Azure AD tenant by the OIDC Metadata endpoint
        [switch]
        $SkipeOidcMetadataEndPoint


        
    )
    
    begin {

        if ($null -eq (Get-MgContext)) {
            Write-Error "Please Connect to MS Graph API with the Connect-MgGraph cmdlet from the Microsoft.Graph.Authentication module first before calling functions!" -ErrorAction Stop
        }

        $GraphEndPoint = (Get-MgEnvironment -Name $Environment).GraphEndpoint
        $AzureADEndpoint = (Get-MgEnvironment -Name $Environment).AzureADEndpoint

        Write-Verbose ("Using $Environment login endpoint of $AzureADEndpoint")
        Write-Verbose ("Using $Environment Graph endpoint of $GraphEndPoint")
    }
    
    process {
        $i = 0
        foreach ($value in $TenantValue) {

            $i++
            Write-Verbose ("Checking Value {0} of {1} - Value: {2}" -f $i, ($($TenantValue).count), $value) 

            $ResolveUri = $null
            $ResolvedTenant = [ordered]@{}
            $ResolvedTenant.Environment = $Environment
            $ResolvedTenant.ValueToResolve = $value

            if (Test-IsGuid -StringGuid $value) {
                Write-Verbose ("Attempting to resolve AzureAD Tenant by TenantID {0}" -f $value)
                $ResolveUri = ("{0}/beta/tenantRelationships/findTenantInformationByTenantId(tenantId='{1}')" -f $GraphEndPoint, $Value)
                $ResolvedTenant.ValueFormat = "TenantId"
            }
            else {

                if (Test-IsDnsDomainName -StringDomainName $value) {
                    Write-Verbose ("Attempting to resolve AzureAD Tenant by DomainName {0}" -f $value)
                    $ResolveUri = ("{0}/beta/tenantRelationships/findTenantInformationByDomainNAme(domainName='{1}')" -f $GraphEndPoint, $Value)
                    $ResolvedTenant.ValueFormat = "DomainName"

                }
                

            }

            if ($null -ne $ResolveUri) {
                try {

                    Write-Verbose ("Resolving Tenant Information using MS Graph API")
                    $Resolve = Invoke-MgGraphRequest -Method Get -Uri $ResolveUri -ErrorAction Stop | Select-Object tenantId, displayName, defaultDomainName, federationBrandName

                    $ResolvedTenant.Result = "Resolved"
                    $ResolvedTenant.ResultMessage = "Resolved Tenant"
                    $ResolvedTenant.TenantId = $Resolve.TenantId
                    $ResolvedTenant.DisplayName = $Resolve.DisplayName
                    $ResolvedTenant.DefaultDomainName = $Resolve.defaultDomainName
                    $ResolvedTenant.FederationBrandName = $Resolve.federationBrandName
                }
                catch {

                    if ($_.Exception.Message -eq 'Response status code does not indicate success: NotFound (Not Found).') {
                        $ResolvedTenant.Result = "NotFound"
                        $ResolvedTenant.ResultMessage = "NotFound (Not Found)"
                    }
                    else {
                        
                        $ResolvedTenant.Result = "Error"
                        $ResolvedTenant.ResultMessage = $_.Exception.Message

                    }
                    
                    $ResolvedTenant.TenantId = $null
                    $ResolvedTenant.DisplayName = $null
                    $ResolvedTenant.DefaultDomainName = $null
                    $ResolvedTenant.FederationBrandName = $null

                }
            }
            else {
                
                $ResolvedTenant.ValueFormat = "Unknown"
                Write-Warning ("{0} value to resolve was not in GUID or DNS Name format, and will be skipped!" -f $value)
                $ResolvedTenant.Status = "Skipped"
            }
           

            if ($true -ne $SkipOidcMetadataEndPoint) {
                $oidcMetadataUri = ("{0}/{1}/v2.0/.well-known/openid-configuration" -f $AzureADEndpoint, $value)

                try {
                
                    $oidcMetadata = Invoke-RestMethod -Method Get -Uri $oidcMetadataUri -ErrorAction Stop
                    $resolvedTenant.oidcMetadataResult = "Resolved"
                    $resolvedTenant.oidcMetadataTenantId = $oidcMetadata.issuer.split("/")[3]
                    $resolvedTenant.oidcMetadataTenantRegionScope = $oidcMetadata.tenant_region_scope

                }
                catch {
                
                    $resolvedTenant.oidcMetadataResult = "NotFound"
                    $resolvedTenant.oidcMetadataTenantId = $null
                    $resolvedTenant.oidcMetadataTenantRegionScope = $null

                }
            }
            else {
                $resolvedTenant.oidcMetadataResult = "Skipped"
                $resolvedTenant.oidcMetadataTenantId = $null
                $resolvedTenant.oidcMetadataTenantRegionScope = $null
            }

            

            Write-Output ([pscustomobject]$ResolvedTenant)

            
        }



        
        
    }
    
    end {
    }
}


function Test-IsGuid {
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$StringGuid
    )
 
    $ObjectGuid = [System.Guid]::empty
    return [System.Guid]::TryParse($StringGuid, [System.Management.Automation.PSReference]$ObjectGuid) # Returns True if successfully parsed
}
 
function Test-IsDnsDomainName {
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$StringDomainName
    )
    $isDnsDomainName = $false
    $DnsHostNameRegex = "\A([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}\Z"
    Write-Verbose ("Checking if DomainName {0} is a valid Dns formatted Uri" -f $StringDomainName)
    if ($StringDomainName -match $DnsHostNameRegex) {
        If ("Dns" -eq [System.Uri]::CheckHostName($StringDomainName)) {
            $isDnsDomainName = $true
        }
    }

    return $isDnsDomainName
}