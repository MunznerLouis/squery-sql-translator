# Import-DbSchema.ps1
# Imports database schema from CSV exports (columns, foreign keys, primary keys)
# and generates Configs/Default/db-schema.json.
#
# Usage:
#   .\Import-DbSchema.ps1 -ColumnsCsv "columns.csv" -ForeignKeysCsv "fk.csv" -PrimaryKeysCsv "pk.csv"
#
# The 3 CSV files come from running the queries in todo/export-db-schema.sql against
# the target database and exporting each result set as a CSV.
#
# CSV separators: auto-detected (comma or semicolon).

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ColumnsCsv,

    [Parameter(Mandatory=$true)]
    [string]$ForeignKeysCsv,

    [Parameter(Mandatory=$true)]
    [string]$PrimaryKeysCsv,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Default output path: Configs/Default/db-schema.json relative to repo root
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot '..\Configs\Default\db-schema.json'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# ---------------------------------------------------------------------------
# Helper: Import CSV with auto-detected delimiter (comma or semicolon)
# ---------------------------------------------------------------------------
function Import-AutoCsv {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path $Path)) {
        throw "$Label file not found: $Path"
    }

    # Read first line to detect delimiter
    $firstLine = Get-Content $Path -TotalCount 1
    $delimiter = if ($firstLine -match ';') { ';' } else { ',' }

    $rows = Import-Csv $Path -Delimiter $delimiter
    if ($rows.Count -eq 0) {
        throw "$Label CSV is empty."
    }
    return $rows
}

# ---------------------------------------------------------------------------
# 1. Load CSV files
# ---------------------------------------------------------------------------
Write-Host "Loading columns CSV..." -ForegroundColor Gray
$columnsRows = Import-AutoCsv -Path $ColumnsCsv -Label "Columns"

Write-Host "Loading foreign keys CSV..." -ForegroundColor Gray
$fkRows = Import-AutoCsv -Path $ForeignKeysCsv -Label "ForeignKeys"

Write-Host "Loading primary keys CSV..." -ForegroundColor Gray
$pkRows = Import-AutoCsv -Path $PrimaryKeysCsv -Label "PrimaryKeys"

# Validate expected columns
$requiredColCols = @('TableName', 'ColumnName', 'DataType', 'Nullable', 'IsIdentity')
foreach ($col in $requiredColCols) {
    if ($null -eq $columnsRows[0].PSObject.Properties[$col]) {
        throw "Columns CSV missing required column '$col'. Expected: $($requiredColCols -join ', ')"
    }
}

$requiredFkCols = @('ParentTable', 'ParentColumn', 'ReferencedTable', 'ReferencedColumn')
foreach ($col in $requiredFkCols) {
    if ($null -eq $fkRows[0].PSObject.Properties[$col]) {
        throw "ForeignKeys CSV missing required column '$col'. Expected: $($requiredFkCols -join ', ')"
    }
}

$requiredPkCols = @('TableName', 'ColumnName')
foreach ($col in $requiredPkCols) {
    if ($null -eq $pkRows[0].PSObject.Properties[$col]) {
        throw "PrimaryKeys CSV missing required column '$col'. Expected: $($requiredPkCols -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# 2. Build the schema structure
# ---------------------------------------------------------------------------
Write-Host "Building schema..." -ForegroundColor Gray

$tables = [ordered]@{}

# 2a. Columns
foreach ($row in $columnsRows) {
    $tableName = $row.TableName.Trim()
    $colName   = $row.ColumnName.Trim()

    if (-not $tables.Contains($tableName)) {
        $tables[$tableName] = [ordered]@{
            columns     = [ordered]@{}
            primaryKey  = @()
            foreignKeys = [ordered]@{}
        }
    }

    # Parse nullable and isIdentity as booleans (handle "0"/"1", "True"/"False", "true"/"false")
    $nullable   = $row.Nullable.Trim()
    $isIdentity = $row.IsIdentity.Trim()

    $nullableBool   = ($nullable -eq '1' -or $nullable -eq 'True' -or $nullable -eq 'true')
    $isIdentityBool = ($isIdentity -eq '1' -or $isIdentity -eq 'True' -or $isIdentity -eq 'true')

    $tables[$tableName].columns[$colName] = [ordered]@{
        dataType   = $row.DataType.Trim()
        nullable   = $nullableBool
        isIdentity = $isIdentityBool
    }
}

# 2b. Primary Keys
foreach ($row in $pkRows) {
    $tableName = $row.TableName.Trim()
    $colName   = $row.ColumnName.Trim()

    if ($tables.Contains($tableName)) {
        $currentPk = [System.Collections.ArrayList]@($tables[$tableName].primaryKey)
        if ($colName -notin $currentPk) {
            $null = $currentPk.Add($colName)
        }
        $tables[$tableName].primaryKey = @($currentPk)
    }
}

# 2c. Foreign Keys
foreach ($row in $fkRows) {
    $parentTable = $row.ParentTable.Trim()
    $parentCol   = $row.ParentColumn.Trim()
    $refTable    = $row.ReferencedTable.Trim()
    $refCol      = $row.ReferencedColumn.Trim()

    if ($tables.Contains($parentTable)) {
        $tables[$parentTable].foreignKeys[$parentCol] = [ordered]@{
            referencedTable  = $refTable
            referencedColumn = $refCol
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Write db-schema.json
# ---------------------------------------------------------------------------
$schema = [ordered]@{
    version     = '1.0'
    description = 'Auto-generated database schema. DO NOT EDIT MANUALLY. Re-generate with Import-DbSchema.ps1.'
    tables      = $tables
}

$json = $schema | ConvertTo-Json -Depth 6
$utf8Bom = [System.Text.UTF8Encoding]::new($true)

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

[System.IO.File]::WriteAllText($OutputPath, $json, $utf8Bom)

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
$tableCount  = $tables.Count
$totalCols   = ($tables.Values | ForEach-Object { $_.columns.Count } | Measure-Object -Sum).Sum
$totalFks    = ($tables.Values | ForEach-Object { $_.foreignKeys.Count } | Measure-Object -Sum).Sum

Write-Host ""
Write-Host "db-schema.json generated successfully!" -ForegroundColor Green
Write-Host "  Tables:       $tableCount" -ForegroundColor Gray
Write-Host "  Columns:      $totalCols" -ForegroundColor Gray
Write-Host "  Foreign Keys: $totalFks" -ForegroundColor Gray
Write-Host "  Output:       $OutputPath" -ForegroundColor Gray
Write-Host ""
