# Import-ResourceEntityTypes.ps1
# Parses Identity Manager EntityType XML and generates resource-columns.json.
#
# Usage:
#   .\Scripts\Import-ResourceEntityTypes.ps1 -XmlPath ".\.sample_data\entityTypes.txt" -OutputPath ".\Configs\Default\resource-columns.json"
#
# Each Property with TargetColumnIndex maps to a C{base32} column name in [dbo].[UR_Resources].
# ForeignKey properties with TargetColumnIndex also get a {Identifier}_Id alias for the FK value.
# Properties without TargetColumnIndex (collection nav props) are skipped.

param(
    [Parameter(Mandatory=$true)]
    [string]$XmlPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\Configs\Default\resource-columns.json",

    [Parameter(Mandatory=$false)]
    [switch]$Merge     # if set, merge into existing file instead of overwriting
)

# Base-32 encoding: alphabet 0-9, A-V (0-9=digits, 10-31=A-V)
function ConvertTo-ResourceColumnName {
    param([int]$Index)
    $alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUV'
    if ($Index -eq 0) { return 'C0' }
    $result = ''
    $n = $Index
    while ($n -gt 0) {
        $charIdx = $n % 32
        $result  = $alphabet[$charIdx].ToString() + $result
        $n       = [int][Math]::Floor($n / 32)
    }
    return 'C' + $result
}

# Load and parse XML
if (-not (Test-Path $XmlPath)) {
    Write-Error "XML file not found: $XmlPath"
    exit 1
}

$xmlContent = Get-Content $XmlPath -Raw -Encoding UTF8
# Wrap in a root element if not already a proper XML document
if ($xmlContent -notmatch '<\?xml') {
    $xmlContent = "<?xml version='1.0' encoding='utf-8'?><EntityTypes>$xmlContent</EntityTypes>"
}

try {
    [xml]$xml = $xmlContent
} catch {
    Write-Error "Failed to parse XML: $($_.Exception.Message)"
    exit 1
}

$root = $xml.DocumentElement
$entityTypeNodes = $root.SelectNodes('//EntityType')

if ($entityTypeNodes.Count -eq 0) {
    Write-Warning "No EntityType elements found in XML."
    exit 0
}

# Load existing if merging
$existing = @{ entityTypes = @{} }
if ($Merge -and (Test-Path $OutputPath)) {
    $existingJson  = Get-Content $OutputPath -Raw | ConvertFrom-Json
    $existing = @{ entityTypes = @{} }
    foreach ($en in $existingJson.entityTypes.PSObject.Properties) {
        $cols = @{}
        foreach ($cp in $en.Value.columns.PSObject.Properties) {
            $cols[$cp.Name] = $cp.Value
        }
        $existing.entityTypes[$en.Name] = @{
            entityTypeId = [int]$en.Value.entityTypeId
            alias        = $en.Value.alias
            columns      = $cols
        }
    }
}

$result = $existing

foreach ($etNode in $entityTypeNodes) {
    $entityName = $etNode.GetAttribute('Identifier')
    if ([string]::IsNullOrWhiteSpace($entityName)) { continue }

    # Derive alias from entity name: initials of CamelCase words, max 5 chars
    $words    = [regex]::Matches($entityName, '[A-Z][a-z0-9_]*') | ForEach-Object { $_.Value }
    $alias    = if ($words.Count -gt 1) {
        ($words | ForEach-Object { $_[0].ToString().ToLower() }) -join ''
    } else {
        $entityName.Substring(0, [Math]::Min(4, $entityName.Length)).ToLower()
    }

    # Keep existing alias if merging
    if ($Merge -and $result.entityTypes.ContainsKey($entityName)) {
        $alias        = $result.entityTypes[$entityName].alias
        $entityTypeId = $result.entityTypes[$entityName].entityTypeId
    } else {
        $entityTypeId = 0
    }

    $columns = @{}
    $columns['Id'] = 'Id'

    foreach ($propNode in $etNode.SelectNodes('Property')) {
        $propId    = $propNode.GetAttribute('Identifier')
        $propType  = $propNode.GetAttribute('Type')
        $targetIdx = $propNode.GetAttribute('TargetColumnIndex')

        if ([string]::IsNullOrWhiteSpace($propId))    { continue }
        if ([string]::IsNullOrWhiteSpace($targetIdx)) { continue }   # skip collections

        $colName = ConvertTo-ResourceColumnName -Index ([int]$targetIdx)
        $columns[$propId] = $colName

        # For ForeignKey properties, also add PropIdentifier_Id -> same column
        # so callers can select the raw FK value using either name
        if ($propType -eq 'ForeignKey') {
            $columns["${propId}_Id"] = $colName
        }
    }

    $result.entityTypes[$entityName] = @{
        entityTypeId = $entityTypeId
        alias        = $alias
        columns      = $columns
    }

    Write-Host "  $entityName : $($columns.Count - 1) columns (alias=$alias)" -ForegroundColor Gray
}

# Build final JSON object (preserve column ordering by sorting keys)
$outputObj = [ordered]@{
    '$schema'   = 'http://json-schema.org/draft-07/schema#'
    version     = '1.0'
    description = 'Resource EntityType column mappings. Each entity stores attributes in [dbo].[UR_Resources] C{base32(TargetColumnIndex)} columns. entityTypeId=0 means unknown (use JOIN on UM_EntityTypes to filter).'
    entityTypes = [ordered]@{}
}

foreach ($en in ($result.entityTypes.Keys | Sort-Object)) {
    $ec = $result.entityTypes[$en]
    $colsOrdered = [ordered]@{}
    # Id first, then sorted
    if ($ec.columns.ContainsKey('Id')) { $colsOrdered['Id'] = 'Id' }
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
# Ensure UTF-8 BOM output
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText((Resolve-Path (Split-Path $OutputPath) | Join-Path -ChildPath (Split-Path $OutputPath -Leaf)), $json, $utf8Bom)

Write-Host "Written: $OutputPath ($($result.entityTypes.Count) entity types)" -ForegroundColor Green
