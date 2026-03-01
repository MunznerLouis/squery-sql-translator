# WorkspaceInitializer.ps1
# Provides Initialize-Workspace and Update-SQueryEntityTypes cmdlets.
# Supports CSV import and SQL Server auto-connect for EntityType discovery.

# ---------------------------------------------------------------------------
# Private helpers (not exported)
# ---------------------------------------------------------------------------

# Base-32 encoding for Resource column names: alphabet 0-9, A-V
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

# Parse semicolon-delimited CSV and return ordered hashtable of entityName -> config
# CSV columns: EntityType_Id;Identifier;Property;TargetColumnIndex
function Read-EntityTypesFromCsv {
    param([string]$CsvPath)

    $rows = Import-Csv $CsvPath -Delimiter ';'
    if ($rows.Count -eq 0) {
        throw "CSV file is empty or has no data rows."
    }

    # Validate expected columns
    $firstRow = $rows[0]
    $requiredCols = @('EntityType_Id', 'Identifier', 'Property', 'TargetColumnIndex')
    foreach ($col in $requiredCols) {
        if ($null -eq $firstRow.PSObject.Properties[$col]) {
            throw "CSV is missing required column '$col'. Expected columns: $($requiredCols -join ';')"
        }
    }

    $result = [ordered]@{}
    foreach ($row in $rows) {
        $entityName   = $row.Identifier
        $entityTypeId = [int]$row.EntityType_Id
        $targetIdx    = [int]$row.TargetColumnIndex
        $colName      = ConvertTo-RCColumnName -Index $targetIdx

        if (-not $result.Contains($entityName)) {
            $alias = Get-EntityAlias -EntityName $entityName
            $result[$entityName] = [ordered]@{
                entityTypeId = $entityTypeId
                alias        = $alias
                columns      = [ordered]@{ Id = 'Id' }
            }
        }
        $result[$entityName].columns[$row.Property] = $colName
    }
    return $result
}

# Connect to SQL Server and run the discovery query, returning the same structure as CSV import
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

        $result = [ordered]@{}
        while ($reader.Read()) {
            $entityName   = $reader['Identifier'].ToString()
            $entityTypeId = [int]$reader['EntityType_Id']
            $targetIdx    = [int]$reader['TargetColumnIndex']
            $colName      = ConvertTo-RCColumnName -Index $targetIdx

            if (-not $result.Contains($entityName)) {
                $alias = Get-EntityAlias -EntityName $entityName
                $result[$entityName] = [ordered]@{
                    entityTypeId = $entityTypeId
                    alias        = $alias
                    columns      = [ordered]@{ Id = 'Id' }
                }
            }
            $result[$entityName].columns[$reader['Property'].ToString()] = $colName
        }
        return $result
    } finally {
        $conn.Close()
    }
}

# Write an entityTypes hashtable to resource-columns.json with UTF-8 BOM
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
    param([object]$EntityTypes)
    foreach ($en in $EntityTypes.Keys) {
        $colCount = $EntityTypes[$en].columns.Count - 1
        Write-Host "  $en (id=$($EntityTypes[$en].entityTypeId)) : $colCount columns (alias=$($EntityTypes[$en].alias))" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Public cmdlets
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
Guided first-time setup for SQuery-SQL-Translator.

.DESCRIPTION
Interactive wizard that generates Configs/Custom/resource-columns.json from
either a direct SQL Server connection or a CSV file exported from SSMS.
Run this once per project before using Convert-SQueryToSql with Resource EntityTypes.

.PARAMETER CsvPath
Path to a semicolon-delimited CSV file (columns: EntityType_Id;Identifier;Property;TargetColumnIndex).
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
    $entityTypes = $null

    # Non-interactive: params provided directly
    if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        $mode = 'csv'
    } elseif (-not [string]::IsNullOrWhiteSpace($ServerInstance)) {
        $mode = 'auto'
    }

    # Interactive: ask the user
    if ($null -eq $mode) {
        Write-Host 'This wizard generates your project-specific EntityType column' -ForegroundColor Gray
        Write-Host 'mappings for Resource EntityTypes.' -ForegroundColor Gray
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
            $entityTypes = Read-EntityTypesFromSqlServer -ServerInstance $ServerInstance -Database $Database -Login $Login -Password $Password
        } catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    # --- MANUAL/CSV mode ---
    if ($mode -eq 'csv') {
        Write-Host 'Step 1: Provide your CSV export.' -ForegroundColor Cyan
        Write-Host '  Run this query in SSMS and export result as semicolon-delimited CSV:' -ForegroundColor Gray
        if (Test-Path $sqlFile) {
            Write-Host "  Query file: $sqlFile" -ForegroundColor Gray
        }
        Write-Host '  Expected columns: EntityType_Id;Identifier;Property;TargetColumnIndex' -ForegroundColor Gray
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
            $entityTypes = Read-EntityTypesFromCsv -CsvPath $CsvPath
        } catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    # --- Write output ---
    if ($null -eq $entityTypes -or $entityTypes.Count -eq 0) {
        Write-Host '  No EntityTypes found.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $customDir)) {
        New-Item -ItemType Directory -Path $customDir -Force | Out-Null
    }

    Write-ResourceColumnsJson -OutputPath $outputPath -EntityTypes $entityTypes

    Show-ImportSummary -EntityTypes $entityTypes

    Write-Host ''
    Write-Host "Imported $($entityTypes.Count) EntityType(s)." -ForegroundColor Green
    Write-Host "Saved to: $outputPath" -ForegroundColor Green
    Write-Host ''
    Write-Host 'You are ready. Run Convert-SQueryToSql -Url <url> to start translating.' -ForegroundColor Cyan
    Write-Host ''
}

<#
.SYNOPSIS
Import or update Resource EntityType column mappings.

.DESCRIPTION
Parses a CSV export (or connects to SQL Server) and writes (or merges into)
Configs/Custom/resource-columns.json. Use -Merge to add new EntityTypes
without replacing existing ones.

.PARAMETER CsvPath
Path to a semicolon-delimited CSV file (columns: EntityType_Id;Identifier;Property;TargetColumnIndex).

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
# Replaces Custom/resource-columns.json entirely from CSV.

.EXAMPLE
Update-SQueryEntityTypes -CsvPath ".\additional.csv" -Merge
# Merges new EntityTypes into the existing file.

.EXAMPLE
Update-SQueryEntityTypes -ServerInstance "myserver" -Database "Usercube" -Login "sa" -Password "pass"
# Replaces Custom/resource-columns.json from SQL Server.
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
            $newEntityTypes = Read-EntityTypesFromCsv -CsvPath $CsvPath
        } else {
            $newEntityTypes = Read-EntityTypesFromSqlServer -ServerInstance $ServerInstance -Database $Database -Login $Login -Password $Password
        }
    } catch {
        Write-Error "Failed: $($_.Exception.Message)"
        return
    }

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

    if (-not (Test-Path $customDir)) {
        New-Item -ItemType Directory -Path $customDir -Force | Out-Null
    }

    Write-ResourceColumnsJson -OutputPath $outputPath -EntityTypes $final

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
    Write-Host "Saved $($final.Count) total EntityType(s) to: $outputPath" -ForegroundColor Cyan
}
