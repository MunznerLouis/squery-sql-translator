# ConfigLoader.ps1
# Loads and validates configuration files for SQuery-SQL-Translator.
#
# Configuration sources (in Configs/Default/):
#   - squery-schema.json  (auto-generated) -- SQuery entities with properties and nav props (from swagger)
#   - sql-schema.json     (auto-generated) -- SQL tables with columns, PKs, FKs (from DB exports)
#   - correlation.json    (manual)         -- entity-to-table bridge, column renames, nav prop overrides
#   - operator.json       (required)       -- SQuery operator -> SQL mapping
#
# Custom overlay:
#   - Configs/Custom/resource-columns.json -- merged into resourceEntityTypes
#
# Performance note:
#   squery-schema.json and sql-schema.json are large (1-2MB). They are kept as raw
#   PSCustomObject (no ConvertToHashtable) and accessed via PSObject property lookup.

class ConfigLoader {
    # Raw config data (small files -> hashtable, big files -> PSCustomObject)
    [object]$SquerySchema           # PSCustomObject from squery-schema.json (large)
    [object]$SqlSchema              # PSCustomObject from sql-schema.json (large)
    [hashtable]$Correlation         # from correlation.json (small, converted)
    [hashtable]$Operators           # from operator.json (small, converted)

    # Derived data
    [hashtable]$ResourceColumns     # built from correlation.resourceEntityTypes + Custom overlay

    # Reverse lookup: raw table name -> entity name
    hidden [hashtable]$TableToEntity

    # Backward-compat: used by Validator and Test-SQueryConfiguration
    [hashtable]$DatabaseMapping

    [string]$ConfigPath

    ConfigLoader([string]$configPath) {
        $this.ConfigPath = $configPath
        $this.LoadConfigurations()
    }

    # ======================================================================
    # Loading
    # ======================================================================

    [void] LoadConfigurations() {
        try {
            # ---- correlation.json (required, small -> ConvertToHashtable) ----
            $correlationPath = Join-Path $this.ConfigPath "correlation.json"
            if (-not (Test-Path $correlationPath)) {
                throw "correlation.json not found at: $correlationPath"
            }
            $correlationJson = Get-Content $correlationPath -Raw | ConvertFrom-Json
            $this.Correlation = $this.ConvertToHashtable($correlationJson)

            # ---- operator.json (required, small -> ConvertToHashtable) -------
            $operatorsPath = Join-Path $this.ConfigPath "operator.json"
            if (-not (Test-Path $operatorsPath)) {
                throw "operator.json not found at: $operatorsPath"
            }
            $operatorsJson = Get-Content $operatorsPath -Raw | ConvertFrom-Json
            $this.Operators = $this.ConvertToHashtable($operatorsJson)

            # ---- squery-schema.json (optional, large -> keep as PSCustomObject)
            $sqSchemaPath = Join-Path $this.ConfigPath "squery-schema.json"
            if (Test-Path $sqSchemaPath) {
                $this.SquerySchema = Get-Content $sqSchemaPath -Raw | ConvertFrom-Json
            } else {
                $this.SquerySchema = $null
            }

            # ---- sql-schema.json (optional, large -> keep as PSCustomObject) -
            $sqlSchemaPath = Join-Path $this.ConfigPath "sql-schema.json"
            if (Test-Path $sqlSchemaPath) {
                $this.SqlSchema = Get-Content $sqlSchemaPath -Raw | ConvertFrom-Json
            } else {
                $this.SqlSchema = $null
            }

            # ---- Build reverse lookup: tableName -> entityName --------------
            $this.TableToEntity = @{}
            if ($this.Correlation.ContainsKey('entityToTable')) {
                foreach ($entityName in $this.Correlation.entityToTable.Keys) {
                    $tbl = $this.Correlation.entityToTable[$entityName]
                    $this.TableToEntity[$tbl] = $entityName
                }
            }

            # ---- Build DatabaseMapping (backward compat for Validator) ------
            $this.BuildDatabaseMapping()

            # ---- Build ResourceColumns from correlation + Custom overlay ----
            $this.BuildResourceColumns()

            # ---- Validate ---------------------------------------------------
            $this.ValidateConfigurations()

        } catch {
            throw "Failed to load configurations from '$($this.ConfigPath)': $($_.Exception.Message)"
        }
    }

    # Build $this.DatabaseMapping from correlation.entityToTable + squery-schema properties.
    hidden [void] BuildDatabaseMapping() {
        $this.DatabaseMapping = @{ tables = @{} }

        if (-not $this.Correlation.ContainsKey('entityToTable')) { return }

        # Get squery entities block (PSCustomObject or $null)
        $sqEntities = $null
        if ($null -ne $this.SquerySchema -and $null -ne $this.SquerySchema.entities) {
            $sqEntities = $this.SquerySchema.entities
        }

        foreach ($entityName in $this.Correlation.entityToTable.Keys) {
            $rawTable = $this.Correlation.entityToTable[$entityName]

            # Determine allowedFields from squery-schema (real property list) or default to ["*"]
            $allowedFields = @('*')
            if ($null -ne $sqEntities) {
                $entitySchema = $sqEntities.$entityName
                if ($null -ne $entitySchema -and $null -ne $entitySchema.properties -and $entitySchema.properties.Count -gt 0) {
                    $allowedFields = @($entitySchema.properties)
                }
            }

            # Auto-generate alias from entity name initials
            $alias = [ConfigLoader]::GenerateAlias($entityName)

            $this.DatabaseMapping.tables[$entityName] = @{
                tableName     = "[dbo].[$rawTable]"
                alias         = $alias
                allowedFields = $allowedFields
            }
        }
    }

    # Build $this.ResourceColumns from correlation.resourceEntityTypes + Custom overlay.
    hidden [void] BuildResourceColumns() {
        $this.ResourceColumns = @{ entityTypes = @{} }

        # Load from correlation.resourceEntityTypes
        if ($this.Correlation.ContainsKey('resourceEntityTypes')) {
            foreach ($enName in $this.Correlation.resourceEntityTypes.Keys) {
                $this.ResourceColumns.entityTypes[$enName] = $this.Correlation.resourceEntityTypes[$enName]
            }
        }

        # Custom overlay: Configs/Custom/resource-columns.json
        $customRcPath = Join-Path (Split-Path $this.ConfigPath -Parent) "Custom\resource-columns.json"
        if (Test-Path $customRcPath) {
            $customRcJson = Get-Content $customRcPath -Raw | ConvertFrom-Json
            $customRc = $this.ConvertToHashtable($customRcJson)
            if ($customRc.ContainsKey('entityTypes')) {
                foreach ($enName in $customRc.entityTypes.Keys) {
                    $this.ResourceColumns.entityTypes[$enName] = $customRc.entityTypes[$enName]
                }
            }
        }
    }

    # ======================================================================
    # Validation
    # ======================================================================

    [void] ValidateConfigurations() {
        # Validate correlation has entityToTable
        if (-not $this.Correlation.ContainsKey('entityToTable')) {
            throw "correlation.json must contain 'entityToTable' key"
        }

        if (-not $this.Operators.ContainsKey('operators')) {
            throw "operator.json must contain 'operators' key"
        }

        # Validate operator definitions
        foreach ($opName in $this.Operators.operators.Keys) {
            $op = $this.Operators.operators[$opName]
            if (-not $op.ContainsKey('sqlOperator')) {
                throw "Operator '$opName' in operator.json must have 'sqlOperator' property"
            }
            if (-not $op.ContainsKey('conditionType')) {
                throw "Operator '$opName' in operator.json must have 'conditionType' property"
            }
            $validConditionTypes = @('comparison', 'pattern', 'set', 'null')
            if ($op.conditionType -notin $validConditionTypes) {
                throw "Operator '$opName' has invalid conditionType '$($op.conditionType)'. Must be one of: $($validConditionTypes -join ', ')"
            }
        }
    }

    # ======================================================================
    # Static: auto-generate alias from entity name
    # ======================================================================

    static [string] GenerateAlias([string]$entityName) {
        # Extract capital-letter-initiated words: AssignedSingleRole -> A, S, R -> asr
        $words = [regex]::Matches($entityName, '[A-Z][a-z0-9_]*')
        if ($words.Count -gt 1) {
            $alias = ''
            foreach ($w in $words) { $alias += $w.Value[0].ToString().ToLower() }
            return $alias
        }
        # Single word: take first 4 chars lowercase
        $len = [Math]::Min(4, $entityName.Length)
        return $entityName.Substring(0, $len).ToLower()
    }

    # ======================================================================
    # Public API
    # ======================================================================

    # Returns @{ tableName; alias; allowedFields } for a known entity,
    # or falls back to Resource EntityType config.
    [hashtable] GetTableMapping([string]$entityName) {
        if ($this.DatabaseMapping.tables.ContainsKey($entityName)) {
            return $this.DatabaseMapping.tables[$entityName]
        }
        # Fallback: Resource EntityType entities share [dbo].[UR_Resources]
        $resConfig = $this.GetResourceEntityConfig($entityName)
        if ($null -ne $resConfig) {
            return @{
                tableName     = '[dbo].[UR_Resources]'
                alias         = $resConfig.alias
                allowedFields = @('*')
            }
        }
        throw "Entity '$entityName' not found in configuration"
    }

    # Checks whether a field is allowed on an entity.
    [bool] IsFieldAllowed([string]$entityName, [string]$fieldName) {
        try {
            $tableMapping = $this.GetTableMapping($entityName)
            if ('*' -in $tableMapping.allowedFields) { return $true }
            return $fieldName -in $tableMapping.allowedFields
        } catch {
            return $false
        }
    }

    # Returns the DB column name for a given SQuery field name, applying:
    #   1. Entity-specific override from correlation.entityColumnOverrides
    #   2. Resource EntityType column map (e.g. DisplayName -> CC)
    #   3. Global renames (e.g. DisplayName -> DisplayName_L1)
    #   4. Auto-rename: FooId -> Foo_Id  (FK naming; skips bare "Id" and already-underscored "_Id")
    [string] GetColumnDbName([string]$entityName, [string]$fieldName) {
        # 1. Entity-specific override (flat map: "SQueryName" -> "DbColumn")
        if ($this.Correlation.ContainsKey('entityColumnOverrides') -and
            $this.Correlation.entityColumnOverrides.ContainsKey($entityName)) {
            $er = $this.Correlation.entityColumnOverrides[$entityName]
            if ($er.ContainsKey($fieldName)) {
                return $er[$fieldName]
            }
        }
        # 2. Resource EntityType column map
        $resConfig = $this.GetResourceEntityConfig($entityName)
        if ($null -ne $resConfig) {
            if ($resConfig.columns.ContainsKey($fieldName)) {
                return $resConfig.columns[$fieldName]
            }
            # 2b. FK alias: PresenceState_Id -> PresenceState (strip _Id suffix and retry)
            if ($fieldName.EndsWith('_Id') -and $fieldName.Length -gt 3) {
                $baseName = $fieldName.Substring(0, $fieldName.Length - 3)
                if ($resConfig.columns.ContainsKey($baseName)) {
                    return $resConfig.columns[$baseName]
                }
            }
        }
        # 3. Global renames
        if ($this.Correlation.ContainsKey('globalColumnRenames') -and
            $this.Correlation.globalColumnRenames.ContainsKey($fieldName)) {
            return $this.Correlation.globalColumnRenames[$fieldName]
        }
        # 4. FK auto-rename: FooId -> Foo_Id (not bare "Id", not already "Foo_Id")
        if ($fieldName -ne 'Id' -and $fieldName.EndsWith('Id') -and -not $fieldName.EndsWith('_Id')) {
            return $fieldName.Substring(0, $fieldName.Length - 2) + '_Id'
        }
        return $fieldName
    }

    # Returns navigation property definition, or $null if not found.
    # Priority:
    #   1. Manual overrides in correlation.json navigationPropertyOverrides
    #   2. Auto-deduction from sql-schema.json foreign keys
    #   3. Resource EntityType generic nav props (correlation.json resourceNavigationProperties)
    # FK convention defaults: localKey = "{navPropName}_Id", foreignKey = "Id"
    [hashtable] GetNavProp([string]$entityName, [string]$navPropName) {
        # 1. Check manual overrides
        $result = $this.GetNavPropFromOverrides($entityName, $navPropName)
        if ($null -ne $result) { return $result }

        # 2. Auto-deduce from sql-schema FK
        $result = $this.GetNavPropFromSqlSchema($entityName, $navPropName)
        if ($null -ne $result) { return $result }

        # 3. Resource EntityType generic nav props
        $result = $this.GetNavPropFromResourceDefaults($entityName, $navPropName)
        if ($null -ne $result) { return $result }

        return $null
    }

    # Returns resource entity config, or $null if not a Resource subtype.
    [hashtable] GetResourceEntityConfig([string]$entityName) {
        if ($null -eq $this.ResourceColumns -or -not $this.ResourceColumns.ContainsKey('entityTypes')) {
            return $null
        }
        $et = $this.ResourceColumns.entityTypes
        if ($et.ContainsKey($entityName)) {
            return $et[$entityName]
        }
        return $null
    }

    # ======================================================================
    # Nav prop resolution helpers
    # ======================================================================

    # Look up nav prop in correlation.json navigationPropertyOverrides.
    hidden [hashtable] GetNavPropFromOverrides([string]$entityName, [string]$navPropName) {
        if (-not $this.Correlation.ContainsKey('navigationPropertyOverrides')) {
            return $null
        }
        $navProps = $this.Correlation.navigationPropertyOverrides
        if (-not $navProps.ContainsKey($entityName)) {
            return $null
        }
        $entityNavProps = $navProps[$entityName]
        if (-not $entityNavProps.ContainsKey($navPropName)) {
            return $null
        }

        $raw = $entityNavProps[$navPropName]

        # Build result with [dbo].[...] prefix on targetTable and FK convention defaults
        $result = @{}
        foreach ($k in $raw.Keys) { $result[$k] = $raw[$k] }

        # Add [dbo].[...] prefix if not already present
        if ($result.ContainsKey('targetTable') -and $result.targetTable -notmatch '^\[') {
            $result.targetTable = "[dbo].[$($result.targetTable)]"
        }

        # Apply FK convention defaults
        if (-not $result.ContainsKey('localKey'))   { $result['localKey']   = "${navPropName}_Id" }
        if (-not $result.ContainsKey('foreignKey')) { $result['foreignKey'] = 'Id' }

        return $result
    }

    # Auto-deduce nav prop from sql-schema.json foreign keys (PSCustomObject access).
    # Looks for column "{navPropName}_Id" with a declared FK in the entity's table.
    hidden [hashtable] GetNavPropFromSqlSchema([string]$entityName, [string]$navPropName) {
        if ($null -eq $this.SqlSchema -or $null -eq $this.SqlSchema.tables) { return $null }

        # Resolve entity -> raw table name (from correlation.entityToTable)
        if (-not $this.Correlation.ContainsKey('entityToTable')) { return $null }
        if (-not $this.Correlation.entityToTable.ContainsKey($entityName)) { return $null }
        $rawTable = $this.Correlation.entityToTable[$entityName]

        # PSCustomObject property access (no .ContainsKey)
        $tableSchema = $this.SqlSchema.tables.$rawTable
        if ($null -eq $tableSchema -or $null -eq $tableSchema.foreignKeys) { return $null }

        $fkCol = "${navPropName}_Id"
        $fk = $tableSchema.foreignKeys.$fkCol
        if ($null -eq $fk) { return $null }

        $refTable  = $fk.referencedTable   # raw table name, e.g. "UP_SingleRoles"
        $refColumn = $fk.referencedColumn  # e.g. "Id"

        # Resolve referenced table back to an entity name
        $targetEntity = $navPropName  # fallback
        if ($this.TableToEntity.ContainsKey($refTable)) {
            $targetEntity = $this.TableToEntity[$refTable]
        }

        return @{
            targetTable  = "[dbo].[$refTable]"
            targetEntity = $targetEntity
            localKey     = $fkCol
            foreignKey   = $refColumn
        }
    }

    # Look up nav prop in correlation.json resourceNavigationProperties (generic Resource EntityType nav props).
    # Only applies when the entity is a Resource EntityType (found in ResourceColumns).
    hidden [hashtable] GetNavPropFromResourceDefaults([string]$entityName, [string]$navPropName) {
        # Only applies to Resource EntityTypes
        $resConfig = $this.GetResourceEntityConfig($entityName)
        if ($null -eq $resConfig) { return $null }

        if (-not $this.Correlation.ContainsKey('resourceNavigationProperties')) { return $null }
        $resNavProps = $this.Correlation.resourceNavigationProperties
        if (-not $resNavProps.ContainsKey($navPropName)) { return $null }

        $raw = $resNavProps[$navPropName]

        $result = @{}
        foreach ($k in $raw.Keys) { $result[$k] = $raw[$k] }

        if ($result.ContainsKey('targetTable') -and $result.targetTable -notmatch '^\[') {
            $result.targetTable = "[dbo].[$($result.targetTable)]"
        }

        if (-not $result.ContainsKey('localKey'))   { $result['localKey']   = "${navPropName}_Id" }
        if (-not $result.ContainsKey('foreignKey')) { $result['foreignKey'] = 'Id' }

        return $result
    }

    # ======================================================================
    # Helper: PSCustomObject -> Hashtable (recursive)
    # Only used for small config files (correlation.json, operator.json).
    # ======================================================================

    [hashtable] ConvertToHashtable([object]$obj) {
        if ($null -eq $obj) {
            return @{}
        }
        $hash = @{}
        $obj.PSObject.Properties | ForEach-Object {
            $key = $_.Name
            $value = $_.Value
            if ($value -is [System.Management.Automation.PSCustomObject]) {
                $hash[$key] = $this.ConvertToHashtable($value)
            } elseif ($value -is [System.Array]) {
                $hash[$key] = @($value | ForEach-Object {
                    if ($_ -is [System.Management.Automation.PSCustomObject]) {
                        $this.ConvertToHashtable($_)
                    } else {
                        $_
                    }
                })
            } else {
                $hash[$key] = $value
            }
        }
        return $hash
    }
}
