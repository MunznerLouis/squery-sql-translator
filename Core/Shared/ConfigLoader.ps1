# ConfigLoader.ps1
# Loads and validates configuration files for SQuery-SQL-Translator.
#
# Configuration sources (in Configs/Default/):
#   - db-schema.json  (optional) — auto-generated table/column/FK schema
#   - overrides.json  (required) — entity aliases, column renames, nav props, resource entity types
#   - operator.json   (required) — SQuery operator → SQL mapping
#
# Custom overlay:
#   - Configs/Custom/resource-columns.json — merged into resourceEntityTypes

class ConfigLoader {
    # Internal data stores
    [hashtable]$DbSchema           # from db-schema.json (may be empty if file absent)
    [hashtable]$Overrides          # from overrides.json
    [hashtable]$Operators          # from operator.json (unchanged)

    # Derived / backward-compat properties
    [hashtable]$DatabaseMapping    # built from Overrides.entityAliases + DbSchema columns
    [hashtable]$ResourceColumns    # built from Overrides.resourceEntityTypes + Custom overlay

    # Reverse lookup: raw table name → entity name (built at load time)
    hidden [hashtable]$TableToEntity

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
            # ---- overrides.json (required) --------------------------------
            $overridesPath = Join-Path $this.ConfigPath "overrides.json"
            if (-not (Test-Path $overridesPath)) {
                throw "overrides.json not found at: $overridesPath"
            }
            $overridesJson = Get-Content $overridesPath -Raw | ConvertFrom-Json
            $this.Overrides = $this.ConvertToHashtable($overridesJson)

            # ---- operator.json (required) ---------------------------------
            $operatorsPath = Join-Path $this.ConfigPath "operator.json"
            if (-not (Test-Path $operatorsPath)) {
                throw "operator.json not found at: $operatorsPath"
            }
            $operatorsJson = Get-Content $operatorsPath -Raw | ConvertFrom-Json
            $this.Operators = $this.ConvertToHashtable($operatorsJson)

            # ---- db-schema.json (optional) --------------------------------
            $dbSchemaPath = Join-Path $this.ConfigPath "db-schema.json"
            if (Test-Path $dbSchemaPath) {
                $dbSchemaJson = Get-Content $dbSchemaPath -Raw | ConvertFrom-Json
                $this.DbSchema = $this.ConvertToHashtable($dbSchemaJson)
            } else {
                $this.DbSchema = @{ tables = @{} }
            }

            # ---- Build reverse lookup: tableName → entityName -------------
            $this.TableToEntity = @{}
            if ($this.Overrides.ContainsKey('entityAliases')) {
                foreach ($entityName in $this.Overrides.entityAliases.Keys) {
                    $tbl = $this.Overrides.entityAliases[$entityName].tableName
                    $this.TableToEntity[$tbl] = $entityName
                }
            }

            # ---- Build DatabaseMapping (backward compat) ------------------
            $this.BuildDatabaseMapping()

            # ---- Build ResourceColumns from overrides + Custom overlay ----
            $this.BuildResourceColumns()

            # ---- Validate -------------------------------------------------
            $this.ValidateConfigurations()

        } catch {
            throw "Failed to load configurations from '$($this.ConfigPath)': $($_.Exception.Message)"
        }
    }

    # Build $this.DatabaseMapping from overrides.entityAliases + db-schema columns.
    # Structure matches the old database-mapping.json format for backward compatibility.
    hidden [void] BuildDatabaseMapping() {
        $this.DatabaseMapping = @{ tables = @{} }

        if (-not $this.Overrides.ContainsKey('entityAliases')) { return }

        foreach ($entityName in $this.Overrides.entityAliases.Keys) {
            $aliasInfo = $this.Overrides.entityAliases[$entityName]
            $rawTable  = $aliasInfo.tableName  # e.g. "UP_AssignedSingleRoles"

            # Determine allowedFields from db-schema (real column list) or default to ["*"]
            $allowedFields = @('*')
            if ($this.DbSchema.tables.ContainsKey($rawTable)) {
                $schemaTable = $this.DbSchema.tables[$rawTable]
                if ($schemaTable.ContainsKey('columns') -and $schemaTable.columns.Count -gt 0) {
                    $allowedFields = @($schemaTable.columns.Keys)
                }
            }

            $this.DatabaseMapping.tables[$entityName] = @{
                tableName     = "[dbo].[$rawTable]"
                alias         = $aliasInfo.alias
                allowedFields = $allowedFields
            }
        }
    }

    # Build $this.ResourceColumns from overrides.resourceEntityTypes + Custom overlay.
    hidden [void] BuildResourceColumns() {
        $this.ResourceColumns = @{ entityTypes = @{} }

        # Load from overrides.resourceEntityTypes
        if ($this.Overrides.ContainsKey('resourceEntityTypes')) {
            foreach ($enName in $this.Overrides.resourceEntityTypes.Keys) {
                $this.ResourceColumns.entityTypes[$enName] = $this.Overrides.resourceEntityTypes[$enName]
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
        # Validate overrides has required keys
        if (-not $this.Overrides.ContainsKey('entityAliases')) {
            throw "overrides.json must contain 'entityAliases' key"
        }

        if (-not $this.Operators.ContainsKey('operators')) {
            throw "operator.json must contain 'operators' key"
        }

        # Validate each entity alias has required properties
        foreach ($entityName in $this.Overrides.entityAliases.Keys) {
            $entity = $this.Overrides.entityAliases[$entityName]
            if (-not $entity.ContainsKey('tableName')) {
                throw "Entity '$entityName' in overrides.json entityAliases must have 'tableName' property"
            }
            if (-not $entity.ContainsKey('alias')) {
                throw "Entity '$entityName' in overrides.json entityAliases must have 'alias' property"
            }
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
    # Public API — same signatures as before
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
    # When db-schema.json is loaded, checks against real column list.
    # Otherwise (allowedFields = ["*"]) allows everything.
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
    #   1. Entity-specific override from overrides.entityColumnOverrides
    #   2. Resource EntityType column map (e.g. DisplayName -> CC)
    #   3. Global renames (e.g. DisplayName -> DisplayName_L1)
    #   4. Auto-rename: FooId -> Foo_Id  (FK naming; skips bare "Id" and already-underscored "_Id")
    [string] GetColumnDbName([string]$entityName, [string]$fieldName) {
        # 1. Entity-specific override
        if ($this.Overrides.ContainsKey('entityColumnOverrides') -and
            $this.Overrides.entityColumnOverrides.ContainsKey($entityName)) {
            $er = $this.Overrides.entityColumnOverrides[$entityName]
            if ($er.ContainsKey($fieldName) -and $er[$fieldName].ContainsKey('dbColumn')) {
                return $er[$fieldName].dbColumn
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
        if ($this.Overrides.ContainsKey('globalColumnRenames') -and
            $this.Overrides.globalColumnRenames.ContainsKey($fieldName)) {
            return $this.Overrides.globalColumnRenames[$fieldName]
        }
        # 4. FK auto-rename: FooId -> Foo_Id (not bare "Id", not already "Foo_Id")
        if ($fieldName -ne 'Id' -and $fieldName.EndsWith('Id') -and -not $fieldName.EndsWith('_Id')) {
            return $fieldName.Substring(0, $fieldName.Length - 2) + '_Id'
        }
        return $fieldName
    }

    # Returns navigation property definition, or $null if not found.
    # Priority:
    #   1. Manual overrides in overrides.json navigationPropertyOverrides
    #   2. Auto-deduction from db-schema.json foreign keys
    # FK convention defaults: localKey = "{navPropName}_Id", foreignKey = "Id"
    [hashtable] GetNavProp([string]$entityName, [string]$navPropName) {
        # 1. Check manual overrides
        $result = $this.GetNavPropFromOverrides($entityName, $navPropName)
        if ($null -ne $result) { return $result }

        # 2. Auto-deduce from db-schema FK
        $result = $this.GetNavPropFromDbSchema($entityName, $navPropName)
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

    # Look up nav prop in overrides.json navigationPropertyOverrides.
    hidden [hashtable] GetNavPropFromOverrides([string]$entityName, [string]$navPropName) {
        if (-not $this.Overrides.ContainsKey('navigationPropertyOverrides')) {
            return $null
        }
        $navProps = $this.Overrides.navigationPropertyOverrides
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

    # Auto-deduce nav prop from db-schema.json foreign keys.
    # Looks for column "{navPropName}_Id" with a declared FK in the entity's table.
    hidden [hashtable] GetNavPropFromDbSchema([string]$entityName, [string]$navPropName) {
        if ($this.DbSchema.tables.Count -eq 0) { return $null }

        # Resolve entity → raw table name
        if (-not $this.Overrides.entityAliases.ContainsKey($entityName)) { return $null }
        $rawTable = $this.Overrides.entityAliases[$entityName].tableName

        if (-not $this.DbSchema.tables.ContainsKey($rawTable)) { return $null }
        $tableSchema = $this.DbSchema.tables[$rawTable]
        if (-not $tableSchema.ContainsKey('foreignKeys')) { return $null }

        $fkCol = "${navPropName}_Id"
        if (-not $tableSchema.foreignKeys.ContainsKey($fkCol)) { return $null }

        $fk = $tableSchema.foreignKeys[$fkCol]
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

    # ======================================================================
    # Helper: PSCustomObject → Hashtable (recursive)
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
