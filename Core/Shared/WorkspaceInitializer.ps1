# WorkspaceInitializer.ps1
# Provides Initialize-Workspace and Update-SQueryEntityTypes cmdlets.
# Supports CSV import and SQL Server auto-connect for EntityType discovery.
# One SQL query / one CSV produces both resource-columns.json and resource-nav-props.json.

# ---------------------------------------------------------------------------
# Private helpers (not exported)
# ---------------------------------------------------------------------------

# Base-32 encoding for Resource scalar column names (TCI 0-127): C{base32}
function ConvertTo-RCColumnName {
    param([int]$Index)
    $alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUV'
    if ($Index -eq 0) { return 'C0' }
    $result = ''
    $n = $Index
    while ($n -gt 0) {
        $result = $alphabet[$n % 32].ToString() + $result
        $n = [int][Math]::Floor($n / 32)
    }
    return 'C' + $result
}

# Base-32 encoding for Resource I-column names (TCI 128-152): I{base32}
function ConvertTo-IColumn {
    param([int]$Index)
    $offset = $Index - 128
    if ($offset -lt 0) { return $null }
    $chars = '0123456789ABCDEFGHIJKLMNOPQRSTUV'
    if ($offset -lt 32) {
        return "I$($chars[$offset])"
    }
    $high = [Math]::Floor($offset / 32)
    $low  = $offset % 32
    return "I$($chars[$high])$($chars[$low])"
}

# Derive a short alias from a CamelCase/underscore entity name
# e.g. Directory_FR_User -> dfru, SAP_Person -> sp
function Get-EntityAlias {
    param([string]$EntityName)
    $words = [regex]::Matches($EntityName, '[A-Z][a-z0-9_]*') | ForEach-Object { $_.Value }
    if ($words.Count -gt 1) {
        return ($words | ForEach-Object { $_[0].ToString().ToLower() }) -join ''
    }
    return $EntityName.Substring(0, [Math]::Min(4, $EntityName.Length)).ToLower()
}

# ---------------------------------------------------------------------------
# CSV / SQL Server readers
# Both return @{ entityTypes = ...; navProps = ... }
#   entityTypes: ordered hashtable entityName -> { entityTypeId, alias, columns }
#   navProps:    ordered hashtable entityName -> { PropertyName -> { column, isMultiValued, targetEntityType, ... } }
# ---------------------------------------------------------------------------

# Parse semicolon-delimited CSV.
# Supports both 4-column (legacy) and 8-column (full) formats.
# 4-col: EntityType_Id;Identifier;Property;TargetColumnIndex
# 8-col: EntityType_Id;Identifier;Property;Property_Id;TargetColumnIndex;Property1;Property2;TargetEntityType
function Read-EntityTypesFromCsv {
    param([string]$CsvPath)

    # Extended 8-column header
    $extHeader = @('EntityType_Id','Identifier','Property','Property_Id','TargetColumnIndex','Property1','Property2','TargetEntityType')
    # Legacy 4-column header
    $legacyHeader = @('EntityType_Id','Identifier','Property','TargetColumnIndex')

    # Detect if CSV has a header row by checking if first line starts with a known column name
    $firstLine = (Get-Content $CsvPath -TotalCount 1).TrimStart([char]0xFEFF)
    $firstField = ($firstLine -split ';')[0].Trim()
    $hasHeader = ($firstField -eq 'EntityType_Id')

    if ($hasHeader) {
        $rows = Import-Csv $CsvPath -Delimiter ';'
    } else {
        # Count columns to pick the right header
        $colCount = ($firstLine -split ';').Count
        $header = if ($colCount -ge 8) { $extHeader } else { $legacyHeader }
        $rows = Import-Csv $CsvPath -Delimiter ';' -Header $header
    }

    if ($rows.Count -eq 0) {
        throw "CSV file is empty or has no data rows."
    }

    # Detect format: check if extended columns exist
    $firstRow = $rows[0]
    $hasExtended = ($null -ne $firstRow.PSObject.Properties['Property_Id'])

    # Build entityTypes (scalar columns) and lookup tables for nav props
    $entityTypes  = [ordered]@{}
    $entityTypeIds = @{}        # EntityType_Id -> Identifier
    $propertyById = @{}         # Property_Id -> { ... }
    $associations = @()         # list of @{ property1Id; property2Id }
    $skippedNative = 0

    foreach ($row in $rows) {
        # Parse EntityType_Id as long (native entities have IDs > 2 billion)
        $etIdRaw = $row.EntityType_Id.Trim()
        if ($etIdRaw -notmatch '^\d+$') { continue }
        $entityTypeId = [long]$etIdRaw

        # Skip native EntityTypes (high bit set, ID >= 0x80000000)
        if ($entityTypeId -ge 2147483648) { $skippedNative++; continue }

        $entityName = $row.Identifier.Trim()
        if ([string]::IsNullOrWhiteSpace($entityName)) { continue }

        $tciRaw = $row.TargetColumnIndex.Trim()
        $tci    = if ($tciRaw -match '^-?\d+$') { [int]$tciRaw } else { $null }

        $entityTypeIds[[int]$entityTypeId] = $entityName

        if (-not $entityTypes.Contains($entityName)) {
            $alias = Get-EntityAlias -EntityName $entityName
            $entityTypes[$entityName] = [ordered]@{
                entityTypeId = [int]$entityTypeId
                alias        = $alias
                columns      = [ordered]@{ Id = 'Id' }
            }
        }

        # Scalar columns: TCI 0-127
        if ($null -ne $tci -and $tci -ge 0 -and $tci -le 127) {
            $colName = ConvertTo-RCColumnName -Index $tci
            $entityTypes[$entityName].columns[$row.Property] = $colName
        }

        # Extended format: collect property lookups and associations
        if ($hasExtended) {
            $propertyId = $row.Property_Id.Trim()
            # Skip NULL property IDs
            if ($propertyId -eq 'NULL' -or [string]::IsNullOrWhiteSpace($propertyId)) { continue }

            $prop1Raw = $row.Property1.Trim()
            $prop2Raw = $row.Property2.Trim()
            $targetET = $row.TargetEntityType.Trim()
            # Normalize NULL literals
            if ($prop1Raw -eq 'NULL') { $prop1Raw = '' }
            if ($prop2Raw -eq 'NULL') { $prop2Raw = '' }
            if ($targetET -eq 'NULL') { $targetET = '' }

            if (-not $propertyById.ContainsKey($propertyId)) {
                $propertyById[$propertyId] = @{
                    entityTypeId      = [int]$entityTypeId
                    entityType        = $entityName
                    property          = $row.Property
                    targetColumnIndex = $tci
                    targetEntityType  = $targetET
                }
            }

            if ($prop1Raw -match '^\d+$' -and $prop2Raw -match '^\d+$') {
                $associations += @{ property1Id = $prop1Raw; property2Id = $prop2Raw }
            }
        }
    }

    if ($skippedNative -gt 0) {
        Write-Host "  Skipped $skippedNative native EntityType rows (built-in, ID >= 2147483648)" -ForegroundColor Gray
    }

    # Build nav props from extended data
    $navProps = [ordered]@{}
    if ($hasExtended) {
        $navProps = New-NavPropsFromPropertyData -PropertyById $propertyById -Associations $associations -EntityTypeIds $entityTypeIds
    }

    return @{ entityTypes = $entityTypes; navProps = $navProps }
}

# Build nav props hashtable from property lookup tables.
# Returns ordered hashtable: entityName -> { PropertyName -> { column, isMultiValued, targetEntityType, partnerProperty, partnerColumn } }
function New-NavPropsFromPropertyData {
    param(
        [hashtable]$PropertyById,
        [array]$Associations,
        [hashtable]$EntityTypeIds
    )

    # Deduplicate associations
    $seenAssoc = @{}
    $uniqueAssoc = @()
    foreach ($a in $Associations) {
        $key    = "$($a.property1Id)-$($a.property2Id)"
        $revKey = "$($a.property2Id)-$($a.property1Id)"
        if (-not $seenAssoc.ContainsKey($key) -and -not $seenAssoc.ContainsKey($revKey)) {
            $seenAssoc[$key] = $true
            $uniqueAssoc += $a
        }
    }

    # Build association partner lookup: propertyId -> partner property info
    $assocPartner = @{}
    foreach ($a in $uniqueAssoc) {
        $p1 = $a.property1Id
        $p2 = $a.property2Id
        if ($PropertyById.ContainsKey($p1) -and $PropertyById.ContainsKey($p2)) {
            $assocPartner[$p1] = $PropertyById[$p2]
            $assocPartner[$p2] = $PropertyById[$p1]
        }
    }

    # Build nav props: TCI 128-152 (mono-valued) or TCI -1 (multi-valued)
    $result = [ordered]@{}

    foreach ($entry in $PropertyById.GetEnumerator()) {
        $propId = $entry.Key
        $info   = $entry.Value
        $tci    = $info.targetColumnIndex
        $et     = $info.entityType

        if ($null -eq $tci) { continue }

        # Mono-valued nav prop: TCI 128-152 -> I-column
        if ($tci -ge 128 -and $tci -le 152) {
            if (-not $result.Contains($et)) {
                $result[$et] = [ordered]@{}
            }
            $iCol = ConvertTo-IColumn -Index $tci
            $navDef = [ordered]@{
                column        = $iCol
                isMultiValued = $false
            }
            if ($assocPartner.ContainsKey($propId)) {
                $partner = $assocPartner[$propId]
                $navDef['targetEntityType'] = $partner.entityType
                $navDef['partnerProperty']  = $partner.property
            }
            if ($info.targetEntityType -match '^\d+$') {
                $tetId = [long]$info.targetEntityType
                if ($tetId -lt 2147483648 -and $EntityTypeIds.ContainsKey([int]$tetId)) {
                    $navDef['targetEntityType'] = $EntityTypeIds[[int]$tetId]
                }
            }
            $result[$et][$info.property] = $navDef
        }
        # Multi-valued nav prop: TCI == -1
        elseif ($tci -eq -1) {
            if (-not $result.Contains($et)) {
                $result[$et] = [ordered]@{}
            }
            $navDef = [ordered]@{
                column        = $null
                isMultiValued = $true
            }
            if ($assocPartner.ContainsKey($propId)) {
                $partner = $assocPartner[$propId]
                $navDef['targetEntityType']  = $partner.entityType
                $navDef['partnerProperty']   = $partner.property
                if ($null -ne $partner.targetColumnIndex -and $partner.targetColumnIndex -ge 128) {
                    $navDef['partnerColumn'] = ConvertTo-IColumn -Index $partner.targetColumnIndex
                }
            }
            if ($info.targetEntityType -match '^\d+$') {
                $tetId = [long]$info.targetEntityType
                if ($tetId -lt 2147483648 -and $EntityTypeIds.ContainsKey([int]$tetId)) {
                    $navDef['targetEntityType'] = $EntityTypeIds[[int]$tetId]
                }
            }
            $result[$et][$info.property] = $navDef
        }
    }

    return $result
}

# Connect to SQL Server and run the discovery query, returning same structure as CSV import
function Read-EntityTypesFromSqlServer {
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$Login,
        [System.Security.SecureString]$Password
    )

    # Read the discovery query from the .sql file
    $sqlFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Scripts\Get-EntityTypeProperties.sql'))
    if (-not (Test-Path $sqlFile)) {
        throw "SQL query file not found: $sqlFile"
    }
    $query = Get-Content $sqlFile -Raw

    # Convert SecureString to plain text for connection string
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $connStr = "Server=$ServerInstance;Database=$Database;User Id=$Login;Password=$plainPwd"
    try {
        $conn = [System.Data.SqlClient.SqlConnection]::new($connStr)
        $conn.Open()
    } catch {
        throw "Failed to connect to SQL Server: $($_.Exception.Message)"
    }

    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 30
        $reader = $cmd.ExecuteReader()

        $entityTypes   = [ordered]@{}
        $entityTypeIds = @{}
        $propertyById  = @{}
        $associations  = @()
        $skippedNative = 0

        while ($reader.Read()) {
            $entityTypeId = [long]$reader['EntityType_Id']

            # Skip native EntityTypes (high bit set, ID >= 0x80000000)
            if ($entityTypeId -ge 2147483648) { $skippedNative++; continue }

            $entityName = $reader['Identifier'].ToString()
            $tciRaw     = $reader['TargetColumnIndex']
            $tci        = if ($tciRaw -isnot [System.DBNull]) { [int]$tciRaw } else { $null }

            $entityTypeIds[[int]$entityTypeId] = $entityName

            if (-not $entityTypes.Contains($entityName)) {
                $alias = Get-EntityAlias -EntityName $entityName
                $entityTypes[$entityName] = [ordered]@{
                    entityTypeId = [int]$entityTypeId
                    alias        = $alias
                    columns      = [ordered]@{ Id = 'Id' }
                }
            }

            # Scalar columns: TCI 0-127
            if ($null -ne $tci -and $tci -ge 0 -and $tci -le 127) {
                $colName = ConvertTo-RCColumnName -Index $tci
                $entityTypes[$entityName].columns[$reader['Property'].ToString()] = $colName
            }

            # Collect property lookups and associations
            $propIdVal = $reader['Property_Id']
            if ($propIdVal -is [System.DBNull]) { continue }
            $propertyId = $propIdVal.ToString()
            $prop1Val   = $reader['Property1']
            $prop2Val   = $reader['Property2']
            $targetET   = if ($reader['TargetEntityType'] -isnot [System.DBNull]) { $reader['TargetEntityType'].ToString() } else { '' }

            if (-not $propertyById.ContainsKey($propertyId)) {
                $propertyById[$propertyId] = @{
                    entityTypeId      = [int]$entityTypeId
                    entityType        = $entityName
                    property          = $reader['Property'].ToString()
                    targetColumnIndex = $tci
                    targetEntityType  = $targetET
                }
            }

            if ($prop1Val -isnot [System.DBNull] -and $prop2Val -isnot [System.DBNull]) {
                $p1s = $prop1Val.ToString()
                $p2s = $prop2Val.ToString()
                if ($p1s -match '^\d+$' -and $p2s -match '^\d+$') {
                    $associations += @{ property1Id = $p1s; property2Id = $p2s }
                }
            }
        }

        if ($skippedNative -gt 0) {
            Write-Host "  Skipped $skippedNative native EntityType rows (built-in, ID >= 2147483648)" -ForegroundColor Gray
        }

        $navProps = New-NavPropsFromPropertyData -PropertyById $propertyById -Associations $associations -EntityTypeIds $entityTypeIds
        return @{ entityTypes = $entityTypes; navProps = $navProps }
    } finally {
        $conn.Close()
    }
}

# ---------------------------------------------------------------------------
# JSON writers
# ---------------------------------------------------------------------------

# Write entityTypes hashtable to resource-columns.json with UTF-8 BOM
function Write-ResourceColumnsJson {
    param([string]$OutputPath, [object]$EntityTypes)

    $outputObj = [ordered]@{
        '$schema'   = 'http://json-schema.org/draft-07/schema#'
        version     = '1.0'
        description = 'Resource EntityType column mappings generated by Initialize-Workspace / Update-SQueryEntityTypes.'
        entityTypes = [ordered]@{}
    }
    foreach ($en in ($EntityTypes.Keys | Sort-Object)) {
        $ec = $EntityTypes[$en]
        $colsOrdered = [ordered]@{}
        if ($ec.columns.Contains('Id')) { $colsOrdered['Id'] = 'Id' }
        foreach ($ck in ($ec.columns.Keys | Where-Object { $_ -ne 'Id' } | Sort-Object)) {
            $colsOrdered[$ck] = $ec.columns[$ck]
        }
        $outputObj.entityTypes[$en] = [ordered]@{
            entityTypeId = $ec.entityTypeId
            alias        = $ec.alias
            columns      = $colsOrdered
        }
    }

    $json = $outputObj | ConvertTo-Json -Depth 6
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($OutputPath, $json, $utf8Bom)
}

# Write nav props hashtable to resource-nav-props.json with UTF-8 BOM
function Write-ResourceNavPropsJson {
    param([string]$OutputPath, [object]$NavProps)

    $outputObj = [ordered]@{
        description       = 'Resource EntityType navigation properties - auto-generated. DO NOT EDIT.'
        generatedAt       = (Get-Date -Format 'yyyy-MM-dd')
        entityTypeNavProps = $NavProps
    }

    $json = $outputObj | ConvertTo-Json -Depth 10
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($OutputPath, $json, $utf8Bom)
}

# Load existing Custom/resource-columns.json into an ordered hashtable
function Read-ExistingResourceColumns {
    param([string]$FilePath)

    $existing = [ordered]@{}
    if (Test-Path $FilePath) {
        $json = Get-Content $FilePath -Raw | ConvertFrom-Json
        foreach ($en in $json.entityTypes.PSObject.Properties) {
            $cols = [ordered]@{}
            foreach ($cp in $en.Value.columns.PSObject.Properties) {
                $cols[$cp.Name] = $cp.Value
            }
            $existing[$en.Name] = [ordered]@{
                entityTypeId = [int]$en.Value.entityTypeId
                alias        = $en.Value.alias
                columns      = $cols
            }
        }
    }
    return $existing
}

# Show summary of imported EntityTypes
function Show-ImportSummary {
    param([object]$EntityTypes, [object]$NavProps)
    $totalNavProps = 0
    foreach ($en in $EntityTypes.Keys) {
        $colCount = $EntityTypes[$en].columns.Count - 1
        $navCount = 0
        if ($null -ne $NavProps -and $NavProps.Contains($en)) {
            $navCount = @($NavProps[$en].Keys).Count
        }
        $totalNavProps += $navCount
        $navInfo = if ($navCount -gt 0) { ", $navCount nav props" } else { '' }
        Write-Host "  $en (id=$($EntityTypes[$en].entityTypeId)) : $colCount columns$navInfo (alias=$($EntityTypes[$en].alias))" -ForegroundColor Gray
    }
    if ($totalNavProps -gt 0) {
        Write-Host "  Total navigation properties: $totalNavProps" -ForegroundColor Gray
    }
}

# Helper: write both output files to Configs/Custom/
function Write-ImportResults {
    param(
        [string]$CustomDir,
        [object]$EntityTypes,
        [object]$NavProps
    )

    if (-not (Test-Path $CustomDir)) {
        New-Item -ItemType Directory -Path $CustomDir -Force | Out-Null
    }

    $rcPath = Join-Path $CustomDir 'resource-columns.json'
    Write-ResourceColumnsJson -OutputPath $rcPath -EntityTypes $EntityTypes

    if ($null -ne $NavProps -and $NavProps.Count -gt 0) {
        $navPath = Join-Path $CustomDir 'resource-nav-props.json'
        Write-ResourceNavPropsJson -OutputPath $navPath -NavProps $NavProps
        return @{ rcPath = $rcPath; navPath = $navPath }
    }
    return @{ rcPath = $rcPath; navPath = $null }
}

# ---------------------------------------------------------------------------
# Public cmdlets
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
Guided first-time setup for SQuery-SQL-Translator.

.DESCRIPTION
Interactive wizard that generates Resource EntityType configs from either a
direct SQL Server connection or a CSV file exported from SSMS.
Produces two files:
  - Configs/Custom/resource-columns.json   (scalar column mappings)
  - Configs/Default/resource-nav-props.json (navigation property definitions)
Run this once per project before using Convert-SQueryToSql with Resource EntityTypes.

.PARAMETER CsvPath
Path to a semicolon-delimited CSV file.
Columns: EntityType_Id;Identifier;Property;Property_Id;TargetColumnIndex;Property1;Property2;TargetEntityType
Skips the interactive menu and imports directly.

.PARAMETER ServerInstance
SQL Server instance name for auto-connect mode (e.g. "localhost\SQLEXPRESS").

.PARAMETER Database
Database name for auto-connect mode (e.g. "Usercube").

.PARAMETER Login
SQL Server login for auto-connect mode.

.PARAMETER Password
SQL Server password for auto-connect mode.

.EXAMPLE
Initialize-Workspace
# Interactive: the wizard asks how to import.

.EXAMPLE
Initialize-Workspace -CsvPath ".\export.csv"
# Non-interactive: imports from CSV directly.

.EXAMPLE
Initialize-Workspace -ServerInstance "myserver" -Database "Usercube" -Login "sa" -Password "pass"
# Non-interactive: connects to SQL Server and imports directly.
#>
function Initialize-Workspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$CsvPath,

        [Parameter(Mandatory=$false)]
        [string]$ServerInstance,

        [Parameter(Mandatory=$false)]
        [string]$Database,

        [Parameter(Mandatory=$false)]
        [string]$Login,

        [Parameter(Mandatory=$false)]
        [System.Security.SecureString]$Password
    )

    $configRoot = Split-Path $script:DefaultConfigPath -Parent
    $customDir  = [System.IO.Path]::GetFullPath((Join-Path $configRoot 'Custom'))

    $outputPath = Join-Path $customDir 'resource-columns.json'
    $sampleCsv  = [System.IO.Path]::GetFullPath((Join-Path $configRoot '..\SampleData\import_example.csv'))
    $sqlFile    = [System.IO.Path]::GetFullPath((Join-Path $configRoot '..\Scripts\Get-EntityTypeProperties.sql'))

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ' SQuery-SQL-Translator Workspace Setup' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''

    # Already initialized?
    if (Test-Path $outputPath) {
        Write-Host 'Custom resource-columns.json already exists:' -ForegroundColor Yellow
        Write-Host "  $outputPath" -ForegroundColor Gray
        Write-Host ''
        Write-Host 'To add or update EntityTypes, use:' -ForegroundColor Gray
        Write-Host '  Update-SQueryEntityTypes -CsvPath <path> [-Merge]' -ForegroundColor White
        Write-Host ''
        return
    }

    # Determine import mode
    $mode = $null
    $importResult = $null

    # Non-interactive: params provided directly
    if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        $mode = 'csv'
    } elseif (-not [string]::IsNullOrWhiteSpace($ServerInstance)) {
        $mode = 'auto'
    }

    # Interactive: ask the user
    if ($null -eq $mode) {
        Write-Host 'This wizard generates your project-specific EntityType column' -ForegroundColor Gray
        Write-Host 'mappings and navigation properties for Resource EntityTypes.' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Output: ' -ForegroundColor Gray -NoNewline
        Write-Host $outputPath -ForegroundColor White
        Write-Host ''
        Write-Host 'Choose import method:' -ForegroundColor Cyan
        Write-Host '  [1] AUTO   - Connect to SQL Server (runs discovery query directly)' -ForegroundColor White
        Write-Host '  [2] MANUAL - Import from CSV file (export from SSMS first)' -ForegroundColor White
        Write-Host ''

        $choice = (Read-Host '  Enter choice (1 or 2)').Trim()
        switch ($choice) {
            '1' { $mode = 'auto' }
            '2' { $mode = 'csv' }
            default {
                Write-Host "  Invalid choice '$choice'. Setup cancelled." -ForegroundColor Yellow
                return
            }
        }
    }

    Write-Host ''

    # --- AUTO mode: connect to SQL Server ---
    if ($mode -eq 'auto') {
        Write-Host 'Step 1: SQL Server Connection' -ForegroundColor Cyan
        if (Test-Path $sqlFile) {
            Write-Host "  Query file: $sqlFile" -ForegroundColor Gray
        }
        Write-Host ''

        if ([string]::IsNullOrWhiteSpace($ServerInstance)) {
            $ServerInstance = (Read-Host '  Server instance (e.g. localhost\SQLEXPRESS)').Trim()
        }
        if ([string]::IsNullOrWhiteSpace($Database)) {
            $Database = (Read-Host '  Database name (e.g. Usercube)').Trim()
        }
        if ([string]::IsNullOrWhiteSpace($Login)) {
            $Login = (Read-Host '  Login').Trim()
        }
        if ($null -eq $Password) {
            $Password = Read-Host '  Password' -AsSecureString
        }

        if ([string]::IsNullOrWhiteSpace($ServerInstance) -or [string]::IsNullOrWhiteSpace($Database) -or
            [string]::IsNullOrWhiteSpace($Login) -or $null -eq $Password -or $Password.Length -eq 0) {
            Write-Host '  Missing connection details. Setup cancelled.' -ForegroundColor Yellow
            return
        }

        Write-Host ''
        Write-Host 'Step 2: Connecting and importing...' -ForegroundColor Cyan
        Write-Host ''

        try {
            $importResult = Read-EntityTypesFromSqlServer -ServerInstance $ServerInstance -Database $Database -Login $Login -Password $Password
        } catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    # --- MANUAL/CSV mode ---
    if ($mode -eq 'csv') {
        Write-Host 'Step 1: Provide your CSV export.' -ForegroundColor Cyan
        Write-Host '  Run the query from Get-EntityTypeProperties.sql in SSMS' -ForegroundColor Gray
        Write-Host '  and export result as semicolon-delimited CSV.' -ForegroundColor Gray
        if (Test-Path $sqlFile) {
            Write-Host "  Query file: $sqlFile" -ForegroundColor Gray
        }
        Write-Host '  Expected columns: EntityType_Id;Identifier;Property;Property_Id;TargetColumnIndex;Property1;Property2;TargetEntityType' -ForegroundColor Gray
        if (Test-Path $sampleCsv) {
            Write-Host "  Sample file: $sampleCsv" -ForegroundColor Gray
        }
        Write-Host ''

        if ([string]::IsNullOrWhiteSpace($CsvPath)) {
            $CsvPath = (Read-Host '  Enter path to your CSV file').Trim('" ')
        }

        if ([string]::IsNullOrWhiteSpace($CsvPath)) {
            Write-Host '  No file provided. Setup cancelled.' -ForegroundColor Yellow
            return
        }

        if (-not (Test-Path $CsvPath)) {
            Write-Host "  File not found: $CsvPath" -ForegroundColor Red
            return
        }

        Write-Host ''
        Write-Host 'Step 2: Importing EntityTypes...' -ForegroundColor Cyan
        Write-Host ''

        try {
            $importResult = Read-EntityTypesFromCsv -CsvPath $CsvPath
        } catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    # --- Write output ---
    $entityTypes = $importResult.entityTypes
    $navProps    = $importResult.navProps

    if ($null -eq $entityTypes -or $entityTypes.Count -eq 0) {
        Write-Host '  No EntityTypes found.' -ForegroundColor Yellow
        return
    }

    $paths = Write-ImportResults -CustomDir $customDir -EntityTypes $entityTypes -NavProps $navProps

    Show-ImportSummary -EntityTypes $entityTypes -NavProps $navProps

    Write-Host ''
    Write-Host "Imported $($entityTypes.Count) EntityType(s)." -ForegroundColor Green
    Write-Host "  Columns:    $($paths.rcPath)" -ForegroundColor Green
    if ($null -ne $paths.navPath) {
        Write-Host "  Nav props:  $($paths.navPath)" -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'You are ready. Run Convert-SQueryToSql -Url <url> to start translating.' -ForegroundColor Cyan
    Write-Host ''
}

<#
.SYNOPSIS
Import or update Resource EntityType column mappings and navigation properties.

.DESCRIPTION
Parses a CSV export (or connects to SQL Server) and writes (or merges into)
Configs/Custom/resource-columns.json and Configs/Default/resource-nav-props.json.
Use -Merge to add new EntityTypes without replacing existing ones.

.PARAMETER CsvPath
Path to a semicolon-delimited CSV file.
Columns: EntityType_Id;Identifier;Property;Property_Id;TargetColumnIndex;Property1;Property2;TargetEntityType

.PARAMETER ServerInstance
SQL Server instance name for auto-connect mode.

.PARAMETER Database
Database name for auto-connect mode.

.PARAMETER Login
SQL Server login for auto-connect mode.

.PARAMETER Password
SQL Server password for auto-connect mode.

.PARAMETER Merge
If specified, new EntityTypes are added to the existing Custom/resource-columns.json.
Existing EntityTypes with the same name are updated; others are preserved.

.EXAMPLE
Update-SQueryEntityTypes -CsvPath ".\export.csv"
# Replaces configs entirely from CSV.

.EXAMPLE
Update-SQueryEntityTypes -CsvPath ".\additional.csv" -Merge
# Merges new EntityTypes into the existing file.

.EXAMPLE
Update-SQueryEntityTypes -ServerInstance "myserver" -Database "Usercube" -Login "sa" -Password "pass"
# Replaces configs from SQL Server.
#>
function Update-SQueryEntityTypes {
    [CmdletBinding(DefaultParameterSetName='FromCsv')]
    param(
        [Parameter(Mandatory=$true, ParameterSetName='FromCsv', Position=0)]
        [string]$CsvPath,

        [Parameter(Mandatory=$true, ParameterSetName='FromSqlServer')]
        [string]$ServerInstance,

        [Parameter(Mandatory=$true, ParameterSetName='FromSqlServer')]
        [string]$Database,

        [Parameter(Mandatory=$true, ParameterSetName='FromSqlServer')]
        [string]$Login,

        [Parameter(Mandatory=$true, ParameterSetName='FromSqlServer')]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory=$false)]
        [switch]$Merge
    )

    $configRoot = Split-Path $script:DefaultConfigPath -Parent
    $customDir  = [System.IO.Path]::GetFullPath((Join-Path $configRoot 'Custom'))

    $outputPath = Join-Path $customDir 'resource-columns.json'

    # Parse EntityTypes from the chosen source
    Write-Host 'Parsing EntityTypes...' -ForegroundColor Gray
    try {
        if ($PSCmdlet.ParameterSetName -eq 'FromCsv') {
            if (-not (Test-Path $CsvPath)) {
                Write-Error "File not found: $CsvPath"
                return
            }
            $importResult = Read-EntityTypesFromCsv -CsvPath $CsvPath
        } else {
            $importResult = Read-EntityTypesFromSqlServer -ServerInstance $ServerInstance -Database $Database -Login $Login -Password $Password
        }
    } catch {
        Write-Error "Failed: $($_.Exception.Message)"
        return
    }

    $newEntityTypes = $importResult.entityTypes
    $navProps       = $importResult.navProps

    if ($newEntityTypes.Count -eq 0) {
        Write-Host 'No EntityTypes found.' -ForegroundColor Yellow
        return
    }

    # Load existing if merging
    $final = [ordered]@{}
    if ($Merge) {
        $final = Read-ExistingResourceColumns -FilePath $outputPath
    }

    # Compute diff
    $added   = [System.Collections.ArrayList]::new()
    $updated = [System.Collections.ArrayList]::new()
    foreach ($en in $newEntityTypes.Keys) {
        if ($final.Contains($en)) { $null = $updated.Add($en) }
        else                      { $null = $added.Add($en)   }
        # Preserve custom alias if merging
        if ($Merge -and $final.Contains($en) -and $final[$en].alias) {
            $newEntityTypes[$en].alias = $final[$en].alias
        }
        $final[$en] = $newEntityTypes[$en]
    }

    $paths = Write-ImportResults -CustomDir $customDir -EntityTypes $final -NavProps $navProps

    # Summary
    if ($added.Count -gt 0) {
        Write-Host "Added   ($($added.Count)): $($added.ToArray() -join ', ')" -ForegroundColor Green
    }
    if ($updated.Count -gt 0) {
        Write-Host "Updated ($($updated.Count)): $($updated.ToArray() -join ', ')" -ForegroundColor Yellow
    }
    $unchanged = $final.Count - $added.Count - $updated.Count
    if ($unchanged -gt 0) {
        Write-Host "Unchanged: $unchanged" -ForegroundColor Gray
    }
    Write-Host "Saved $($final.Count) total EntityType(s)." -ForegroundColor Cyan
    Write-Host "  Columns:   $($paths.rcPath)" -ForegroundColor Cyan
    if ($null -ne $paths.navPath) {
        Write-Host "  Nav props: $($paths.navPath)" -ForegroundColor Cyan
    }
}
