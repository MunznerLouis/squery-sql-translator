# Scripts/Generate-DbSchema.ps1
# Regenerates the 'tables' section of Configs/Default/db-schema.json by correlating:
#   - .sample_data/swagger.json       -> SQuery-level field names per entity (swagger prop + capitalize)
#   - .sample_data/ForeignKeys.csv    -> FK relationships for nav prop auto-deduction
#
# The 'entityAliases' section in db-schema.json is the source of truth (edit manually).
# This script reads it, regenerates 'tables', and writes both back.
#
# Usage:
#   .\Scripts\Generate-DbSchema.ps1
#   .\Scripts\Generate-DbSchema.ps1 -WhatIf   (report only, no file written)
#   .\Scripts\Generate-DbSchema.ps1 -Verbose

[CmdletBinding()]
param(
    [string]$SampleDataPath = "$PSScriptRoot\..\.sample_data",
    [string]$ConfigPath     = "$PSScriptRoot\..\Configs\Default",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ============================================================
# Load entityAliases from existing db-schema.json (source of truth)
# ============================================================
$outputPath = Join-Path $ConfigPath "db-schema.json"
if (-not (Test-Path $outputPath)) {
    throw "db-schema.json not found at: $outputPath. Create it with an 'entityAliases' section first."
}
$existingDbSchema = Get-Content $outputPath -Raw | ConvertFrom-Json
if ($null -eq $existingDbSchema.entityAliases) {
    throw "db-schema.json does not contain 'entityAliases'. Add entity name/alias entries manually before regenerating."
}

# Load overrides.json for Step 4 nav prop analysis only (no longer needs entityAliases)
$overridesPath = Join-Path $ConfigPath "overrides.json"
$overrides = if (Test-Path $overridesPath) { Get-Content $overridesPath -Raw | ConvertFrom-Json } else { $null }

$entityToTable  = @{}           # entityName   -> raw table name
$tableToEntity  = @{}           # rawTableName -> entityName
$entityAliases  = [ordered]@{}  # preserved for output

foreach ($prop in $existingDbSchema.entityAliases.PSObject.Properties | Sort-Object Name) {
    $eName  = $prop.Name
    $tName  = $prop.Value.tableName
    $entityToTable[$eName] = $tName
    $tableToEntity[$tName] = $eName
    $entityAliases[$eName] = [ordered]@{ tableName = $tName; alias = $prop.Value.alias }
}
Write-Host "Loaded entityAliases from db-schema.json: $($entityToTable.Count) entities." -ForegroundColor Cyan

# ============================================================
# Step 1 - Parse swagger.json
# Produces: entitySwaggerProps  (entityName -> ordered @{ SQueryPropName -> type })
# ============================================================
Write-Host "`nStep 1: Parsing swagger.json (may take a few seconds)..." -ForegroundColor Cyan

$swaggerPath = Join-Path $SampleDataPath "swagger.json"
if (-not (Test-Path $swaggerPath)) { throw "swagger.json not found: $swaggerPath" }
$swagger = Get-Content $swaggerPath -Raw | ConvertFrom-Json

$entitySwaggerProps  = @{}   # entityName -> @{ sqName -> type }
$schemasByEntity     = @{}   # entityName -> [schemaFullName, ...]
$skippedSchemas      = 0

foreach ($prop in $swagger.components.schemas.PSObject.Properties) {
    $schemaName = $prop.Name

    # Only process *.Api.Entities.* schemas  (skip ViewModels, CommandResults, etc.)
    if ($schemaName -notmatch '\.Api\.Entities\.' -and $schemaName -notmatch '\.Api\.QueryResults\.') { continue }

    # Entity name = last dot-segment
    $segments   = $schemaName -split '\.'
    $entityName = $segments[-1]

    # Only process entities we know about
    if (-not $entityToTable.ContainsKey($entityName)) {
        $skippedSchemas++
        continue
    }

    if (-not $schemasByEntity.ContainsKey($entityName)) {
        $schemasByEntity[$entityName] = [System.Collections.ArrayList]::new()
    }
    $null = $schemasByEntity[$entityName].Add($schemaName)
}

Write-Verbose "Skipped $skippedSchemas schema entries (unknown entities or non-entity schemas)."

# Resolve ambiguity: when multiple schemas match same entity, pick the one with most properties.
foreach ($entityName in $schemasByEntity.Keys) {
    $candidates = $schemasByEntity[$entityName]

    $chosenSchema = $null
    $bestCount    = -1
    foreach ($sName in $candidates) {
        $s     = $swagger.components.schemas.$sName
        $count = if ($null -ne $s.properties) { $s.properties.PSObject.Properties.Count } else { 0 }
        if ($count -gt $bestCount) { $bestCount = $count; $chosenSchema = $sName }
    }
    if ($candidates.Count -gt 1) {
        Write-Warning "Multiple swagger schemas for '$entityName' - using: $chosenSchema ($bestCount props)"
    }

    $schema = $swagger.components.schemas.$chosenSchema
    if ($null -eq $schema -or $null -eq $schema.properties) { continue }

    $props = [ordered]@{}
    foreach ($p in $schema.properties.PSObject.Properties) {
        $camelProp = $p.Name
        $propDef   = $p.Value

        # Capitalize first letter -> SQuery property name
        $sqName = $camelProp.Substring(0,1).ToUpper() + $camelProp.Substring(1)

        # --- Classify property ---

        # Skip: arrays (collection nav props)
        if ($propDef.type -eq 'array') { continue }

        # Skip: direct $ref (navigation property object)
        if ($null -ne $propDef.'$ref') { continue }

        # Skip: allOf (nullable $ref pattern in OpenAPI 3.0)
        if ($null -ne $propDef.allOf) { continue }

        # Skip: generic dictionary  { type: object, additionalProperties: {} }
        if ($propDef.type -eq 'object') { continue }

        # Scalar: string / integer / boolean / number
        $dtype = $propDef.type
        if ($propDef.format) { $dtype = "$($propDef.type)/$($propDef.format)" }
        $props[$sqName] = if ($dtype) { $dtype } else { 'unknown' }
    }

    if ($props.Count -gt 0) {
        $entitySwaggerProps[$entityName] = $props
        Write-Verbose "  $entityName ($($entityToTable[$entityName])): $($props.Count) SQuery fields"
    }
}

Write-Host "  Entities with swagger coverage: $($entitySwaggerProps.Count) / $($entityToTable.Count)"

# ============================================================
# Step 2 - Parse ForeignKeys.csv
# Produces: tableForeignKeys  (rawTable -> @{ colName -> { referencedTable, referencedColumn } })
# ============================================================
Write-Host "`nStep 2: Parsing ForeignKeys.csv..." -ForegroundColor Cyan

$fkPath = Join-Path $SampleDataPath "ForeignKeys.csv"
if (-not (Test-Path $fkPath)) { throw "ForeignKeys.csv not found: $fkPath" }

$tableForeignKeys = @{}
$fkLines = Get-Content $fkPath
$fkCount = 0

foreach ($line in $fkLines | Select-Object -Skip 1) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split ';'
    if ($parts.Count -lt 4) { continue }

    $parentTable = $parts[0].Trim()
    $parentCol   = $parts[1].Trim()
    $refTable    = $parts[2].Trim()
    $refCol      = $parts[3].Trim()

    if (-not $tableForeignKeys.ContainsKey($parentTable)) {
        $tableForeignKeys[$parentTable] = @{}
    }
    $tableForeignKeys[$parentTable][$parentCol] = @{
        referencedTable  = $refTable
        referencedColumn = $refCol
    }
    $fkCount++
}
Write-Host "  Loaded $fkCount FK entries across $($tableForeignKeys.Count) tables."

# ============================================================
# Step 3 - Build tables section
# Only include tables referenced by known entities in entityAliases.
# ============================================================
Write-Host "`nStep 3: Building db-schema.json..." -ForegroundColor Cyan

$dbSchema = [ordered]@{
    '$schema'     = 'http://json-schema.org/draft-07/schema#'
    version       = '1.0'
    description   = 'DB schema config. entityAliases: edit manually. tables: auto-generated by Generate-DbSchema.ps1.'
    entityAliases = $entityAliases
    tables        = [ordered]@{}
}

$sortedTables = $entityToTable.Values | Sort-Object -Unique

foreach ($rawTable in $sortedTables) {
    $entityName  = $tableToEntity[$rawTable]
    $tableEntry  = [ordered]@{}

    # columns: SQuery-level property names from swagger (used for allowedFields in Validator)
    if ($entitySwaggerProps.ContainsKey($entityName) -and $entitySwaggerProps[$entityName].Count -gt 0) {
        $tableEntry['columns'] = $entitySwaggerProps[$entityName]
    }

    # foreignKeys: raw DB FK columns -> { referencedTable, referencedColumn }
    if ($tableForeignKeys.ContainsKey($rawTable) -and $tableForeignKeys[$rawTable].Count -gt 0) {
        $fks = [ordered]@{}
        foreach ($colName in ($tableForeignKeys[$rawTable].Keys | Sort-Object)) {
            $fks[$colName] = [ordered]@{
                referencedTable  = $tableForeignKeys[$rawTable][$colName].referencedTable
                referencedColumn = $tableForeignKeys[$rawTable][$colName].referencedColumn
            }
        }
        $tableEntry['foreignKeys'] = $fks
    }

    if ($tableEntry.Count -gt 0) {
        $dbSchema.tables[$rawTable] = $tableEntry
    }
}

Write-Host "  Tables written: $($dbSchema.tables.Count)"

# ============================================================
# Step 4 - Report auto-deducible navigationPropertyOverrides
# These entries could be REMOVED from overrides.json since db-schema FK auto-deduction covers them.
# ============================================================
Write-Host "`nStep 4: Analyzing redundant navigationPropertyOverrides..." -ForegroundColor Cyan

$canRemove    = @{}
$mustKeep     = @{}

if ($null -ne $overrides -and $null -ne $overrides.navigationPropertyOverrides) {
    foreach ($entityProp in $overrides.navigationPropertyOverrides.PSObject.Properties) {
        $eName    = $entityProp.Name
        $rawTable = if ($entityToTable.ContainsKey($eName)) { $entityToTable[$eName] } else { $null }

        foreach ($navPropProp in $entityProp.Value.PSObject.Properties) {
            $npName  = $navPropProp.Name
            $npDef   = $navPropProp.Value

            # Detect non-standard FK (won't be auto-deduced)
            $hasCustomLocal   = ($null -ne $npDef.localKey)   -and ($npDef.localKey   -ne "${npName}_Id")
            $hasCustomForeign = ($null -ne $npDef.foreignKey) -and ($npDef.foreignKey -ne 'Id')
            $isReverseFk      = $hasCustomForeign   # foreignKey != Id means FK is on child table

            if ($hasCustomLocal -or $hasCustomForeign) {
                if (-not $mustKeep.Contains($eName)) { $mustKeep[$eName] = [System.Collections.ArrayList]::new() }
                $reason = if ($isReverseFk) { "reverse-FK" } elseif ($hasCustomLocal) { "custom localKey=$($npDef.localKey)" } else { "custom" }
                $null = $mustKeep[$eName].Add("$npName ($reason)")
                continue
            }

            # Check if DB FK exists for {npName}_Id on this table
            $fkCol = "${npName}_Id"
            if ($null -ne $rawTable -and $tableForeignKeys.ContainsKey($rawTable) -and $tableForeignKeys[$rawTable].ContainsKey($fkCol)) {
                $refTableName    = $tableForeignKeys[$rawTable][$fkCol].referencedTable
                $autoTargetEntity = if ($tableToEntity.ContainsKey($refTableName)) { $tableToEntity[$refTableName] } else { $npName }
                $configTarget     = $npDef.targetEntity

                if ($autoTargetEntity -eq $configTarget) {
                    if (-not $canRemove.Contains($eName)) { $canRemove[$eName] = [System.Collections.ArrayList]::new() }
                    $null = $canRemove[$eName].Add($npName)
                } else {
                    if (-not $mustKeep.Contains($eName)) { $mustKeep[$eName] = [System.Collections.ArrayList]::new() }
                    $null = $mustKeep[$eName].Add("$npName (target mismatch: auto=$autoTargetEntity vs config=$configTarget)")
                }
            } else {
                if (-not $mustKeep.Contains($eName)) { $mustKeep[$eName] = [System.Collections.ArrayList]::new() }
                $null = $mustKeep[$eName].Add("$npName (no FK found in DB)")
            }
        }
    }
}

$totalCanRemove = ($canRemove.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
$totalMustKeep  = ($mustKeep.Values  | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum

if ($canRemove.Count -gt 0) {
    Write-Host "`n  CAN BE REMOVED ($totalCanRemove entries - auto-deducible from FK):" -ForegroundColor Yellow
    foreach ($e in $canRemove.Keys) {
        Write-Host "    $e : $($canRemove[$e] -join ', ')" -ForegroundColor DarkYellow
    }
}
if ($mustKeep.Count -gt 0) {
    Write-Host "`n  MUST KEEP ($totalMustKeep entries - non-standard or no FK):" -ForegroundColor Green
    foreach ($e in $mustKeep.Keys) {
        Write-Host "    $e : $($mustKeep[$e] -join ', ')" -ForegroundColor DarkGreen
    }
}

# ============================================================
# Output
# ============================================================
$sw.Stop()

if (-not $WhatIf) {
    $dbSchema | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
    Write-Host "`nGenerated: $outputPath" -ForegroundColor Green
} else {
    Write-Host "`n[WhatIf] Would write: $outputPath" -ForegroundColor DarkGray
}

Write-Host "Done in $($sw.Elapsed.TotalSeconds.ToString('0.0'))s" -ForegroundColor Cyan
Write-Host "Tables in db-schema: $($dbSchema.tables.Count)"
Write-Host "Entities without swagger coverage: $(($entityToTable.Keys | Where-Object { -not $entitySwaggerProps.ContainsKey($_) }) -join ', ')"
