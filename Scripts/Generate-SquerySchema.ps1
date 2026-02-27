# Scripts/Generate-SquerySchema.ps1
# Generates Configs/Default/squery-schema.json from .sample_data/swagger.json
#
# For each entity found in swagger (*.Api.Entities.* and *.Api.QueryResults.*),
# classifies every property as:
#   - scalar property  (type: string/integer/boolean/number, or $ref to enum schema)
#   - navigation property  ($ref to entity schema, allOf with entity $ref, or { type: object })
#   - collection nav prop  (type: array with items.$ref)
#
# Output structure:
#   { entities: { EntityName: { properties: [...], navigationProperties: { NavProp: { targetEntity, isCollection } } } } }
#
# Usage:
#   .\Scripts\Generate-SquerySchema.ps1
#   .\Scripts\Generate-SquerySchema.ps1 -WhatIf

[CmdletBinding()]
param(
    [string]$SwaggerPath = "$PSScriptRoot\..\.sample_data\swagger.json",
    [string]$OutputPath  = "$PSScriptRoot\..\Configs\Default\squery-schema.json",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SwaggerPath)) { throw "swagger.json not found: $SwaggerPath" }
Write-Host "Parsing swagger.json..." -ForegroundColor Cyan

$swagger = Get-Content $SwaggerPath -Raw | ConvertFrom-Json
$schemas = $swagger.components.schemas

# Step 1: Build set of enum schema full names (schemas with 'enum' key)
$enumSchemas = [System.Collections.Generic.HashSet[string]]::new()
foreach ($prop in $schemas.PSObject.Properties) {
    if ($null -ne $prop.Value.enum) {
        $null = $enumSchemas.Add($prop.Name)
    }
}
Write-Host "  Enum schemas found: $($enumSchemas.Count)"

# Step 2: Collect entity schemas (*.Api.Entities.* and *.Api.QueryResults.*)
# When multiple schemas match the same entity name, pick the one with most properties.
$entityCandidates = @{}  # entityName -> @{ schemaName, propCount }

foreach ($prop in $schemas.PSObject.Properties) {
    $schemaName = $prop.Name
    if ($schemaName -notmatch '\.Api\.Entities\.' -and $schemaName -notmatch '\.Api\.QueryResults\.') { continue }

    $segments   = $schemaName -split '\.'
    $entityName = $segments[-1]

    $schema = $prop.Value
    $propCount = 0
    if ($null -ne $schema.properties) {
        $propCount = @($schema.properties.PSObject.Properties).Count
    }

    if (-not $entityCandidates.ContainsKey($entityName) -or $propCount -gt $entityCandidates[$entityName].propCount) {
        $entityCandidates[$entityName] = @{ schemaName = $schemaName; propCount = $propCount }
    }
}

Write-Host "  Entity schemas found: $($entityCandidates.Count)"

# Helper: resolve $ref path to schema full name
function Resolve-RefName([string]$ref) {
    return $ref -replace '^#/components/schemas/', ''
}

# Helper: check if a $ref target is an enum schema
function Test-IsEnum([string]$refName) {
    return $enumSchemas.Contains($refName)
}

# Helper: extract entity name from a schema full name
function Get-EntityNameFromSchema([string]$schemaName) {
    $parts = $schemaName -split '\.'
    return $parts[-1]
}

# Step 3: Process each entity and classify properties
$entities = [ordered]@{}

foreach ($entityName in ($entityCandidates.Keys | Sort-Object)) {
    $info       = $entityCandidates[$entityName]
    $schema     = $schemas.($info.schemaName)
    if ($null -eq $schema.properties) { continue }

    $properties    = [System.Collections.ArrayList]::new()
    $navProperties = [ordered]@{}

    foreach ($p in $schema.properties.PSObject.Properties) {
        $camelProp = $p.Name
        $propDef   = $p.Value

        # Capitalize first letter -> SQuery property name
        $sqName = $camelProp.Substring(0,1).ToUpper() + $camelProp.Substring(1)

        # --- Classify property ---

        # Direct $ref
        if ($null -ne $propDef.'$ref') {
            $refName = Resolve-RefName $propDef.'$ref'
            if (Test-IsEnum $refName) {
                # Enum $ref -> scalar property
                $null = $properties.Add($sqName)
            } else {
                # Entity $ref -> navigation property
                $targetEntity = Get-EntityNameFromSchema $refName
                $navProperties[$sqName] = [ordered]@{
                    targetEntity = $targetEntity
                    isCollection = $false
                }
            }
            continue
        }

        # allOf (nullable $ref in OpenAPI 3.0)
        if ($null -ne $propDef.allOf) {
            $aRef = $propDef.allOf[0].'$ref'
            if ($null -ne $aRef) {
                $refName = Resolve-RefName $aRef
                if (Test-IsEnum $refName) {
                    $null = $properties.Add($sqName)
                } else {
                    $targetEntity = Get-EntityNameFromSchema $refName
                    $navProperties[$sqName] = [ordered]@{
                        targetEntity = $targetEntity
                        isCollection = $false
                    }
                }
            }
            continue
        }

        # Array -> collection nav prop
        if ($propDef.type -eq 'array') {
            $targetEntity = $null
            if ($null -ne $propDef.items -and $null -ne $propDef.items.'$ref') {
                $targetEntity = Get-EntityNameFromSchema (Resolve-RefName $propDef.items.'$ref')
            }
            $navProperties[$sqName] = [ordered]@{
                targetEntity = $targetEntity
                isCollection = $true
            }
            continue
        }

        # Object with no $ref -> nav prop with unknown target (e.g. Owner, Performer)
        if ($propDef.type -eq 'object') {
            $navProperties[$sqName] = [ordered]@{
                targetEntity = $null
                isCollection = $false
            }
            continue
        }

        # Scalar: string, integer, boolean, number
        $null = $properties.Add($sqName)
    }

    $entityDef = [ordered]@{
        properties = @($properties.ToArray())
    }
    if ($navProperties.Count -gt 0) {
        $entityDef['navigationProperties'] = $navProperties
    }
    $entities[$entityName] = $entityDef
}

# Step 4: Output
$output = [ordered]@{
    description = "SQuery entity schema - auto-generated from swagger.json by Generate-SquerySchema.ps1. DO NOT EDIT."
    generatedAt = (Get-Date -Format 'yyyy-MM-dd')
    entities    = $entities
}

if (-not $WhatIf) {
    $output | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8
    Write-Host "Generated: $OutputPath" -ForegroundColor Green
} else {
    Write-Host "[WhatIf] Would write: $OutputPath" -ForegroundColor DarkGray
}

Write-Host "Entities: $($entities.Count)" -ForegroundColor Cyan
Write-Host "  With nav props: $(($entities.Values | Where-Object { $_.navigationProperties.Count -gt 0 }).Count)"

# Stats
$totalScalar = ($entities.Values | ForEach-Object { $_.properties.Count } | Measure-Object -Sum).Sum
$totalNavProps = ($entities.Values | Where-Object { $_.Contains('navigationProperties') } | ForEach-Object { $_.navigationProperties.Count } | Measure-Object -Sum).Sum
Write-Host "  Total scalar properties: $totalScalar"
Write-Host "  Total navigation properties: $totalNavProps"
