# Scripts/Generate-SqlSchema.ps1
# Generates Configs/Default/sql-schema.json from DB CSV exports:
#   - .sample_data/ColumnsTables.csv  (TableName;ColumnName;DataType;MaxLength;Nullable;IsIdentity;OrdinalPosition)
#   - .sample_data/ForeignKeys.csv    (ParentTable;ParentColumn;ReferencedTable;ReferencedColumn;FK_Name;OnDelete;OnUpdate)
#   - .sample_data/PrimaryKeys.csv    (TableName;ColumnName;PK_Name)
#
# Output structure:
#   { tables: { TableName: { columns: { col: type }, primaryKey: [col], foreignKeys: { col: { referencedTable, referencedColumn } } } } }
#
# Usage:
#   .\Scripts\Generate-SqlSchema.ps1
#   .\Scripts\Generate-SqlSchema.ps1 -WhatIf

[CmdletBinding()]
param(
    [string]$SampleDataPath = "$PSScriptRoot\..\.sample_data",
    [string]$OutputPath     = "$PSScriptRoot\..\Configs\Default\sql-schema.json",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Step 1: Parse ColumnsTables.csv
# ============================================================
Write-Host "Step 1: Parsing ColumnsTables.csv..." -ForegroundColor Cyan

$columnsPath = Join-Path $SampleDataPath "ColumnsTables.csv"
if (-not (Test-Path $columnsPath)) { throw "ColumnsTables.csv not found: $columnsPath" }

$tables = [ordered]@{}
$lines = Get-Content $columnsPath
$lineNum = 0

foreach ($line in $lines) {
    $lineNum++
    if ($lineNum -eq 1) { continue }  # skip header
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line -split ';'
    if ($parts.Count -lt 5) { continue }

    $tableName  = $parts[0].Trim()
    $columnName = $parts[1].Trim()
    $dataType   = $parts[2].Trim()
    # parts[3] = MaxLength (or Nullable depending on CSV variant)
    # parts[4] = Nullable (or IsIdentity)
    # Handle both 5-col and 7-col variants by checking count
    $nullable   = $false
    $isIdentity = $false

    if ($parts.Count -ge 7) {
        # 7-column format: TableName;ColumnName;DataType;MaxLength;Nullable;IsIdentity;Ordinal
        $nullable   = $parts[4].Trim() -eq '1'
        $isIdentity = $parts[5].Trim() -eq '1'
    } elseif ($parts.Count -ge 5) {
        # 5-column format: TableName;ColumnName;DataType;Nullable;IsIdentity
        $nullable   = $parts[3].Trim() -eq '1'
        $isIdentity = $parts[4].Trim() -eq '1'
    }

    if (-not $tables.Contains($tableName)) {
        $tables[$tableName] = [ordered]@{
            columns = [ordered]@{}
        }
    }
    $tables[$tableName].columns[$columnName] = $dataType
}

Write-Host "  Tables: $($tables.Count)"
$totalCols = ($tables.Values | ForEach-Object { @($_.columns.Keys).Count } | Measure-Object -Sum).Sum
Write-Host "  Columns: $totalCols"

# ============================================================
# Step 2: Parse PrimaryKeys.csv
# ============================================================
Write-Host "`nStep 2: Parsing PrimaryKeys.csv..." -ForegroundColor Cyan

$pkPath = Join-Path $SampleDataPath "PrimaryKeys.csv"
if (-not (Test-Path $pkPath)) { throw "PrimaryKeys.csv not found: $pkPath" }

$pkCount = 0
$pkLines = Get-Content $pkPath
$lineNum = 0

foreach ($line in $pkLines) {
    $lineNum++
    if ($lineNum -eq 1) { continue }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line -split ';'
    if ($parts.Count -lt 2) { continue }

    $tableName  = $parts[0].Trim()
    $columnName = $parts[1].Trim()

    if ($tables.Contains($tableName)) {
        if (-not $tables[$tableName].Contains('primaryKey')) {
            $tables[$tableName]['primaryKey'] = [System.Collections.ArrayList]::new()
        }
        $null = $tables[$tableName].primaryKey.Add($columnName)
        $pkCount++
    }
}

Write-Host "  Primary key columns: $pkCount"

# ============================================================
# Step 3: Parse ForeignKeys.csv
# ============================================================
Write-Host "`nStep 3: Parsing ForeignKeys.csv..." -ForegroundColor Cyan

$fkPath = Join-Path $SampleDataPath "ForeignKeys.csv"
if (-not (Test-Path $fkPath)) { throw "ForeignKeys.csv not found: $fkPath" }

$fkCount = 0
$fkLines = Get-Content $fkPath
$lineNum = 0

foreach ($line in $fkLines) {
    $lineNum++
    if ($lineNum -eq 1) { continue }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line -split ';'
    if ($parts.Count -lt 4) { continue }

    $parentTable = $parts[0].Trim()
    $parentCol   = $parts[1].Trim()
    $refTable    = $parts[2].Trim()
    $refCol      = $parts[3].Trim()

    if ($tables.Contains($parentTable)) {
        if (-not $tables[$parentTable].Contains('foreignKeys')) {
            $tables[$parentTable]['foreignKeys'] = [ordered]@{}
        }
        $tables[$parentTable].foreignKeys[$parentCol] = [ordered]@{
            referencedTable  = $refTable
            referencedColumn = $refCol
        }
        $fkCount++
    }
}

Write-Host "  Foreign key entries: $fkCount"

# ============================================================
# Output
# ============================================================
$output = [ordered]@{
    description = "SQL Server schema - auto-generated from DB exports by Generate-SqlSchema.ps1. DO NOT EDIT."
    generatedAt = (Get-Date -Format 'yyyy-MM-dd')
    tables      = $tables
}

if (-not $WhatIf) {
    $output | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8
    Write-Host "`nGenerated: $OutputPath" -ForegroundColor Green
} else {
    Write-Host "`n[WhatIf] Would write: $OutputPath" -ForegroundColor DarkGray
}

Write-Host "Tables: $($tables.Count), Columns: $totalCols, PKs: $pkCount, FKs: $fkCount" -ForegroundColor Cyan
