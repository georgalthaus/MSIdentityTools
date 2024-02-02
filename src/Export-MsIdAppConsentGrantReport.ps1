﻿<#
.SYNOPSIS
    Lists and categorizes privilege for delegated permissions (OAuth2PermissionGrants) and application permissions (AppRoleAssignments).

.DESCRIPTION
    This cmdlet requires the `ImportExcel` module to be installed if you use the `-ReportOutputType ExcelWorkbook` parameter.

.EXAMPLE
    PS > Install-Module ImportExcel

    PS > Connect-MgGragh -Scopes Application.Read.All

    PS > Export-MsIdAppConsentGrantReport -ReportOutputType ExcelWorkbook -ExcelWorkbookPath .\report.xlsx

    Output a report in Excel format

.EXAMPLE
    PS > Export-MsIdAppConsentGrantReport -ReportOutputType ExcelWorkbook -ExcelWorkbookPath .\report.xlsx -PermissionsTableCsvPath .\table.csv

    Output a report in Excel format and specify a local path for a customized CSV containing consent privilege categorizations

#>
function Export-MsIdAppConsentGrantReport {
    [CmdletBinding(DefaultParameterSetName = 'Download Permissions Table Data',
        SupportsShouldProcess = $true,
        PositionalBinding = $false,
        ConfirmImpact = 'Medium')]
    [Alias()]
    [OutputType([String])]
    Param (

        # Output type for the report.
        [ValidateSet("ExcelWorkbook", "PowerShellObjects")]
        [string]
        $ReportOutputType = "ExcelWorkbook",

        # Output file location for Excel Workbook
        [Parameter(ParameterSetName = 'Excel Workbook Output')]
        [Parameter(Mandatory = $false)]
        [string]
        $ExcelWorkbookPath,

        # Path to CSV file for Permissions Table
        # If not provided the default table will be downloaded from GitHub https://raw.githubusercontent.com/AzureAD/MSIdentityTools/main/assets/aadconsentgrantpermissiontable.csv
        [string]
        $PermissionsTableCsvPath
    )

    begin {

        Set-StrictMode -Off

        function GenerateExcelReport {
            param (
                $evaluatedData,
                $Path
            )

            $autoSize = $IsWindows # AutoSize of columns only works on Windows

            # Delete the existing output file if it already exists
            $OutputFileExists = Test-Path $Path
            if ($OutputFileExists -eq $true) {
                Get-ChildItem $Path | Remove-Item -Force
            }

            $count = 0
            $highprivilegeobjects = $evaluatedData | Where-Object { $_.Privilege -eq "High" }
            $highprivilegeobjects | ForEach-Object {
                $userAssignmentRequired = @()
                $userAssignments = @()
                $userAssignmentsCount = @()
                $userAssignmentRequired = Get-MgServicePrincipal -ServicePrincipalId $_.ClientObjectId

                if ($userAssignmentRequired.AppRoleAssignmentRequired -eq $true) {
                    $userAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $_.ClientObjectId -All
                    $userAssignmentsCount = $userAssignments.count
                    Add-Member -InputObject $_ -MemberType NoteProperty -Name UsersAssignedCount -Value $userAssignmentsCount
                }
                elseif ($userAssignmentRequired.AppRoleAssignmentRequired -eq $false) {
                    $userAssignmentsCount = "AllUsers"
                    Add-Member -InputObject $_ -MemberType NoteProperty -Name UsersAssignedCount -Value $userAssignmentsCount
                }

                $count++
                Write-Progress -Activity "Counting users assigned to high privilege apps . . ." -Status "Apps Counted: $count of $($highprivilegeobjects.Count)" -PercentComplete (($count / $highprivilegeobjects.Count) * 100)
            }
            $highprivilegeusers = $highprivilegeobjects | Where-Object { $null -ne $_.PrincipalObjectId } | Select-Object PrincipalDisplayName, Privilege | Sort-Object PrincipalDisplayName -Unique
            $highprivilegeapps = $highprivilegeobjects | Select-Object ClientDisplayName, Privilege, UsersAssignedCount, MicrosoftRegisteredClientApp | Sort-Object ClientDisplayName -Unique | Sort-Object UsersAssignedCount -Descending

            # Pivot table by user
            $pt = New-PivotTableDefinition -SourceWorksheet ConsentGrantData `
                -PivotTableName "PermissionsByUser" `
                -PivotFilter PrivilegeFilter, PermissionFilter, ResourceDisplayNameFilter, ConsentTypeFilter, ClientDisplayName, MicrosoftRegisteredClientApp `
                -PivotRows PrincipalDisplayName `
                -PivotColumns Privilege, PermissionType `
                -PivotData @{Permission = 'Count' } `
                -IncludePivotChart `
                -ChartType ColumnStacked `
                -ChartHeight 800 `
                -ChartWidth 1200 `
                -ChartRow 4 `
                -ChartColumn 14 `
                -WarningAction SilentlyContinue

            # Pivot table by resource
            $pt += New-PivotTableDefinition -SourceWorksheet ConsentGrantData `
                -PivotTableName "PermissionsByResource" `
                -PivotFilter PrivilegeFilter, ResourceDisplayNameFilter, ConsentTypeFilter, PrincipalDisplayName, MicrosoftRegisteredClientApp `
                -PivotRows ResourceDisplayName, PermissionFilter `
                -PivotColumns Privilege, PermissionType `
                -PivotData @{Permission = 'Count' } `
                -IncludePivotChart `
                -ChartType ColumnStacked `
                -ChartHeight 800 `
                -ChartWidth 1200 `
                -ChartRow 4 `
                -ChartColumn 14 `
                -WarningAction SilentlyContinue

            # Pivot table by privilege rating
            $pt += New-PivotTableDefinition -SourceWorksheet ConsentGrantData `
                -PivotTableName "PermissionsByPrivilegeRating" `
                -PivotFilter PrivilegeFilter, PermissionFilter, ResourceDisplayNameFilter, ConsentTypeFilter, PrincipalDisplayName, MicrosoftRegisteredClientApp `
                -PivotRows Privilege, ResourceDisplayName `
                -PivotColumns PermissionType `
                -PivotData @{Permission = 'Count' } `
                -IncludePivotChart `
                -ChartType ColumnStacked `
                -ChartHeight 800 `
                -ChartWidth 1200 `
                -ChartRow 4 `
                -ChartColumn 5 `
                -WarningAction SilentlyContinue


            $style = New-ExcelStyle -BackgroundColor LightBlue -Bold -Range "A1:Q1"

            $excel = $data | Export-Excel -Path $Path -WorksheetName ConsentGrantData `
                -PivotTableDefinition $pt `
                -FreezeTopRow `
                -AutoFilter `
                -AutoSize:$autoSize `
                -Activate `
                -Style $style `
                -HideSheet "None" `
                -UnHideSheet "PermissionsByPrivilegeRating" `
                -PassThru


            $xlTempFile = [system.io.path]::GetTempFileName()
            $exceltemp = $highprivilegeusers | Export-Excel $xlTempFile -PassThru
            Add-Worksheet -ExcelPackage $excel -WorksheetName HighPrivilegeUsers -CopySource $exceltemp.Workbook.Worksheets["Sheet1"] | Out-Null
            Remove-Item $xlTempFile -ErrorAction Ignore

            Write-Verbose "Create temporary Excel file and add High Privilege Apps sheet"
            $xlTempFile = [system.io.path]::GetTempFileName()
            $exceltemp = $highprivilegeapps | Export-Excel $xlTempFile -PassThru
            Add-Worksheet -ExcelPackage $excel -WorksheetName HighPrivilegeApps -CopySource $exceltemp.Workbook.Worksheets["Sheet1"] -Activate | Out-Null
            Remove-Item $xlTempFile -ErrorAction Ignore

            $sheet = $excel.Workbook.Worksheets["ConsentGrantData"]
            Add-ConditionalFormatting -Worksheet $sheet -Range "A1:N1048576" -RuleType Equal -ConditionValue "High" -ForegroundColor White -BackgroundColor Red -Bold -Underline
            Add-ConditionalFormatting -Worksheet $sheet -Range "A1:N1048576" -RuleType Equal -ConditionValue "Medium" -ForegroundColor Black -BackgroundColor Orange -Bold -Underline
            Add-ConditionalFormatting -Worksheet $sheet -Range "A1:N1048576" -RuleType Equal -ConditionValue "Low" -ForegroundColor Black -BackgroundColor Yellow -Bold -Underline

            $sheet = $excel.Workbook.Worksheets["HighPrivilegeUsers"]
            Add-ConditionalFormatting -Worksheet $sheet -Range "B1:B1048576" -RuleType Equal -ConditionValue "High" -ForegroundColor White -BackgroundColor Red -Bold -Underline
            Set-ExcelRange -Worksheet $sheet -Range A1:C1048576 -AutoSize:$autoSize

            $sheet = $excel.Workbook.Worksheets["HighPrivilegeApps"]
            Add-ConditionalFormatting -Worksheet $sheet -Range "B1:B1048576" -RuleType Equal -ConditionValue "High" -ForegroundColor White -BackgroundColor Red -Bold -Underline
            Set-ExcelRange -Worksheet $sheet -Range A1:C1048576 -AutoSize:$autoSize

            Export-Excel -ExcelPackage $excel | Out-Null
            Write-Verbose ("Excel workbook {0}" -f $ExcelWorkbookPath)
        }

        function Get-MSCloudIdConsentGrantList {
            [CmdletBinding()]
            param(
                [int] $PrecacheSize = 999
            )
            # An in-memory cache of objects by {object ID} andy by {object class, object ID}
            $script:ObjectByObjectId = @{}
            $script:ObjectByObjectClassId = @{}
            $script:KnownMSTenantIds = @("f8cdef31-a31e-4b4a-93e4-5f571e91255a", "72f988bf-86f1-41af-91ab-2d7cd011db47")

            # Function to add an object to the cache
            function CacheObject($Object) {
                if ($Object) {
                    if (-not $script:ObjectByObjectClassId.ContainsKey($Object.GetType().name)) {
                        $script:ObjectByObjectClassId[$Object.GetType().name] = @{}
                    }
                    $script:ObjectByObjectClassId[$Object.GetType().name][$Object.Id] = $Object
                    $script:ObjectByObjectId[$Object.Id] = $Object
                }
            }

            # Function to retrieve an object from the cache (if it's there), or from Entra ID (if not).
            function GetObjectByObjectId($ObjectId) {
                if (-not $script:ObjectByObjectId.ContainsKey($ObjectId)) {
                    Write-Verbose ("Querying Entra ID for object '{0}'" -f $ObjectId)
                    try {
                        $object = (Get-MgDirectoryObjectById -Ids $ObjectId)
                        CacheObject -Object $object
                    }
                    catch {
                        Write-Verbose "Object not found."
                    }
                }
                return $script:ObjectByObjectId[$ObjectId]
            }

            function GetDelegatePermissions($allServicePrincipals) {
                $count = 0
                $permissions = @()
                foreach ($client in $servicePrincipals) {
                    $count++
                    Write-Progress -Activity "Retrieving delegate permissions..." -Status "$count of $($servicePrincipals.Count)" -PercentComplete (($count / $servicePrincipals.Count) * 100)

                    $isMicrosoftApp = $client.AppOwnerOrganizationId -in $script:KnownMSTenantIds

                    $oAuth2PermGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $client.Id -All

                    foreach ($grant in $oAuth2PermGrants) {
                        if ($grant.Scope) {
                            $grant.Scope.Split(" ") | Where-Object { $_ } | ForEach-Object {
                                $scope = $_
                                $resource = GetObjectByObjectId -ObjectId $grant.ResourceId
                                $principalDisplayName = ""

                                if ($grant.PrincipalId) {
                                    $principal = GetObjectByObjectId -ObjectId $grant.PrincipalId
                                    $principalDisplayName = $principal.AdditionalProperties.displayName
                                }

                                $simplifiedgranttype = ""
                                if ($grant.ConsentType -eq "AllPrincipals") {
                                    $simplifiedgranttype = "Delegated-AllPrincipals"
                                }
                                elseif ($grant.ConsentType -eq "Principal") {
                                    $simplifiedgranttype = "Delegated-Principal"
                                }

                                $permissions += New-Object PSObject -Property ([ordered]@{
                                        "PermissionType"               = $simplifiedgranttype
                                        "ConsentTypeFilter"            = $simplifiedgranttype
                                        "ClientObjectId"               = $client.Id
                                        "ClientDisplayName"            = $client.DisplayName
                                        "ResourceObjectId"             = $grant.ResourceId
                                        "ResourceObjectIdFilter"       = $grant.ResourceId
                                        "ResourceDisplayName"          = $resource.AdditionalProperties.displayName
                                        "ResourceDisplayNameFilter"    = $resource.AdditionalProperties.displayName
                                        "Permission"                   = $scope
                                        "PermissionFilter"             = $scope
                                        "PrincipalObjectId"            = $grant.PrincipalId
                                        "PrincipalDisplayName"         = $principalDisplayName
                                        "MicrosoftRegisteredClientApp" = $isMicrosoftApp
                                        "AppOwnerOrganizationId"       = $client.AppOwnerOrganizationId
                                    })
                            }
                        }
                    }

                }
                return $permissions
            }

            function GetApplicationPermissions($allServicePrincipals) {
                $count = 0
                $permissions = @()

                foreach ($client in $servicePrincipals) {
                    $count++
                    Write-Progress -Activity "Retrieving application permissions..." -Status "$count of $($servicePrincipals.Count)" -PercentComplete (($count / $servicePrincipals.Count) * 100)

                    $isMicrosoftApp = $client.AppOwnerOrganizationId -in $script:KnownMSTenantIds

                    $appPermissions = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $client.Id -All

                    foreach ($grant in $appPermissions) {

                        # Look up the related SP to get the name of the permission from the AppRoleId GUID
                        $appRole = $sp.AppRoles | Where-Object { $_.id -eq $grant.AppRoleId } | Select-Object -First 1
                        $appRoleValue = $assignment.AppRoleId
                        if ($null -ne $appRole.value -and $appRole.Value -ne "") {
                            $appRoleValue = $appRole.Value
                        }

                        $permissions += New-Object PSObject -Property ([ordered]@{
                                "PermissionType"               = "Application"
                                "ClientObjectId"               = $client.PrincipalId
                                "ClientDisplayName"            = $client.DisplayName
                                "ResourceObjectId"             = $grant.ResourceId
                                "ResourceObjectIdFilter"       = $grant.ResourceId
                                "ResourceDisplayName"          = $grant.ResourceDisplayName
                                "ResourceDisplayNameFilter"    = $grant.ResourceDisplayName
                                "Permission"                   = $appRoleValue
                                "PermissionFilter"             = $appRoleValue
                                "ConsentTypeFilter"            = "Application"
                                "MicrosoftRegisteredClientApp" = $isMicrosoftApp
                                "AppOwnerOrganizationId"       = $client.AppOwnerOrganizationId
                            })
                    }
                }
                return $permissions
            }

            # Get all ServicePrincipal objects and add to the cache
            Write-Verbose "Retrieving ServicePrincipal objects..."

            Write-Progress -Activity "Retrieving service principal count..."
            $count = Get-MgServicePrincipalCount -ConsistencyLevel eventual
            Write-Progress -Activity "Retrieving $count service principals." -Status "This can take some time please wait..."
            $servicePrincipals = Get-MgServicePrincipal -ExpandProperty "appRoleAssignedTo" -All

            # # Get one page of User objects and add to the cache
            # Write-Verbose "Retrieving User objects..."
            # Get-MgUser -Top $PrecacheSize | ForEach-Object { CacheObject -Object $_ }

            $allPermissions = @()
            $allPermissions += GetDelegatePermissions $servicePrincipals
            $allPermissions += GetApplicationPermissions $servicePrincipals

            return $allPermissions
        }

        function EvaluateConsentGrants {
            param (
                $data
            )

            # Process Privilege for gathered data
            $count = 0
            $data | ForEach-Object {
                try {
                    $count++
                    Write-Progress -Activity "Processing privilege for each permission . . ." -Status "Processed: $count of $($data.Count)" -PercentComplete (($count / $data.Count) * 100)

                    $scope = $_.Permission
                    if ($_.PermissionType -eq "Delegated-AllPrincipals" -or "Delegated-Principal") {
                        $type = "Delegated"
                    }
                    elseif ($_.PermissionType -eq "Application") {
                        $type = "Application"
                    }

                    # Check permission table for an exact match
                    $privilege = $null
                    $scoperoot = @()
                    Write-Debug ("Permission Scope: $Scope")

                    if ($scope -match '.') {
                        $scoperoot = $scope.Split(".")[0]
                    }
                    else {
                        $scoperoot = $scope
                    }

                    $test = ($permstable | Where-Object { $_.Permission -eq "$scoperoot" -and $_.Type -eq $type }).Privilege # checking if there is a matching root in the CSV
                    $privilege = ($permstable | Where-Object { $_.Permission -eq "$scope" -and $_.Type -eq $type }).Privilege # Checking for an exact match

                    # Search for matching root level permission if there was no exact match
                    if (!$privilege -and $test) {
                        # No exact match, but there is a root match
                        $privilege = ($permstable | Where-Object { $_.Permission -eq "$scoperoot" -and $_.Type -eq $type }).Privilege
                    }
                    elseif (!$privilege -and !$test -and $type -eq "Application" -and $scope -like "*Write*") {
                        # Application permissions without exact or root matches with write scope
                        $privilege = "High"
                    }
                    elseif (!$privilege -and !$test -and $type -eq "Application" -and $scope -notlike "*Write*") {
                        # Application permissions without exact or root matches without write scope
                        $privilege = "Medium"
                    }
                    elseif ($privilege) {

                    }
                    else {
                        # Any permissions without a match, should be primarily Delegated permissions
                        $privilege = "Unranked"
                    }

                    # Add the privilege to the current object
                    Add-Member -InputObject $_ -MemberType NoteProperty -Name Privilege -Value $privilege
                    Add-Member -InputObject $_ -MemberType NoteProperty -Name PrivilegeFilter -Value $privilege
                }
                catch {
                    Write-Error "Error Processing Permission for $_"
                }
                finally {
                    Write-Output $_
                }
            }
        }

        function GetPermissionsTable {
            param (
                $PermissionsTableCsvPath
            )

            if ($null -like $PermissionsTableCsvPath) {
                # Create hash table of permissions and permissions privilege
                $permstable = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/AzureAD/MSIdentityTools/main/assets/aadconsentgrantpermissiontable.csv' | ConvertFrom-Csv -Delimiter ','
            }
            else {

                $permstable = Import-Csv $PermissionsTableCsvPath -Delimiter ','
            }

            Write-Output $permstable
        }

        if ("ExcelWorkbook" -eq $ReportOutputType) {
            # Determine if the ImportExcel module is installed since the parameter was included
            if ($null -eq (Get-Module -Name ImportExcel -ListAvailable)) {
                throw "The ImportExcel module is not installed. This is used to export the results to an Excel worksheet. Please install the ImportExcel Module before using this parameter or run without this parameter."
            }
        }
    }
    process {
        $permstable = GetPermissionsTable -PermissionsTableCsvPath $PermissionsTableCsvPath

        Write-Verbose "Retrieving Permission Grants from Entra ID..."
        $data = Get-MSCloudIdConsentGrantList
        if ($null -ne $data) {
            $evaluatedData = EvaluateConsentGrants -data $data
        }
    }
    end {
        if ("ExcelWorkbook" -eq $ReportOutputType) {
            Write-Verbose "Generating Excel Workbook at $ExcelWorkbookPath"
            GenerateExcelReport -evaluatedData $evaluatedData -Path $ExcelWorkbookPath
        }
        else {
            Write-Output $evaluatedData
        }
        Set-StrictMode -Version Latest
    }
}