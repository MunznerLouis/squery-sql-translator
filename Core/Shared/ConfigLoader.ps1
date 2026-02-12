# ConfigLoader.ps1
# Loads and validates JSON configuration files for SQuery-SQL-Translator

class ConfigLoader {
    [hashtable]$DatabaseMapping
    [hashtable]$ColumnRules
    [hashtable]$Operators
    [hashtable]$JoinPatterns
    [hashtable]$ResourceColumns
    [string]$ConfigPath

    ConfigLoader([string]$configPath) {
        $this.ConfigPath = $configPath
        $this.LoadConfigurations()
    }

    [void] LoadConfigurations() {
        # Load with error handling and validation
        try {
            # Load database-mapping.json
            $dbMappingPath = Join-Path $this.ConfigPath "database-mapping.json"
            if (-not (Test-Path $dbMappingPath)) {
                throw "database-mapping.json not found at: $dbMappingPath"
            }
            $dbMappingJson = Get-Content $dbMappingPath -Raw | ConvertFrom-Json
            $this.DatabaseMapping = $this.ConvertToHashtable($dbMappingJson)

            # Load column-rules.json
            $columnRulesPath = Join-Path $this.ConfigPath "column-rules.json"
            if (-not (Test-Path $columnRulesPath)) {
                throw "column-rules.json not found at: $columnRulesPath"
            }
            $columnRulesJson = Get-Content $columnRulesPath -Raw | ConvertFrom-Json
            $this.ColumnRules = $this.ConvertToHashtable($columnRulesJson)

            # Load operator.json
            $operatorsPath = Join-Path $this.ConfigPath "operator.json"
            if (-not (Test-Path $operatorsPath)) {
                throw "operator.json not found at: $operatorsPath"
            }
            $operatorsJson = Get-Content $operatorsPath -Raw | ConvertFrom-Json
            $this.Operators = $this.ConvertToHashtable($operatorsJson)

            # Join patterns optional
            $joinPatternsPath = Join-Path $this.ConfigPath "join-patterns.json"
            if (Test-Path $joinPatternsPath) {
                $joinPatternsJson = Get-Content $joinPatternsPath -Raw | ConvertFrom-Json
                $this.JoinPatterns = $this.ConvertToHashtable($joinPatternsJson)
            } else {
                $this.JoinPatterns = @{}
            }

            # Resource columns optional (Resource EntityType attribute mapping)
            $resourceColumnsPath = Join-Path $this.ConfigPath "resource-columns.json"
            if (Test-Path $resourceColumnsPath) {
                $resourceColumnsJson = Get-Content $resourceColumnsPath -Raw | ConvertFrom-Json
                $this.ResourceColumns = $this.ConvertToHashtable($resourceColumnsJson)
            } else {
                $this.ResourceColumns = @{}
            }

            # Custom resource columns overlay (Configs/Custom/resource-columns.json)
            $customRcPath = Join-Path (Split-Path $this.ConfigPath -Parent) "Custom\resource-columns.json"
            if (Test-Path $customRcPath) {
                $customRcJson = Get-Content $customRcPath -Raw | ConvertFrom-Json
                $customRc = $this.ConvertToHashtable($customRcJson)
                if ($customRc.ContainsKey('entityTypes')) {
                    if (-not $this.ResourceColumns.ContainsKey('entityTypes')) {
                        $this.ResourceColumns['entityTypes'] = @{}
                    }
                    foreach ($enName in $customRc.entityTypes.Keys) {
                        $this.ResourceColumns.entityTypes[$enName] = $customRc.entityTypes[$enName]
                    }
                }
            }

            # Validate configurations
            $this.ValidateConfigurations()

        } catch {
            throw "Failed to load configurations from '$($this.ConfigPath)': $($_.Exception.Message)"
        }
    }

    [void] ValidateConfigurations() {
        # Validate required keys exist
        if (-not $this.DatabaseMapping.ContainsKey('tables')) {
            throw "database-mapping.json must contain 'tables' key"
        }

        if (-not $this.ColumnRules.ContainsKey('entities')) {
            throw "column-rules.json must contain 'entities' key"
        }

        if (-not $this.Operators.ContainsKey('operators')) {
            throw "operator.json must contain 'operators' key"
        }

        # Cross-validate: entities in column-rules should exist in database-mapping (warning only)
        foreach ($entity in $this.ColumnRules.entities.Keys) {
            if (-not $this.DatabaseMapping.tables.ContainsKey($entity)) {
                Write-Warning "ConfigLoader: entity '$entity' in column-rules.json not found in database-mapping.json"
            }
        }

        # Validate that each entity has required properties
        foreach ($entityName in $this.DatabaseMapping.tables.Keys) {
            $entity = $this.DatabaseMapping.tables[$entityName]

            if (-not $entity.ContainsKey('tableName')) {
                throw "Entity '$entityName' in database-mapping.json must have 'tableName' property"
            }

            if (-not $entity.ContainsKey('alias')) {
                throw "Entity '$entityName' in database-mapping.json must have 'alias' property"
            }

            if (-not $entity.ContainsKey('allowedFields')) {
                throw "Entity '$entityName' in database-mapping.json must have 'allowedFields' property"
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
        throw "Entity '$entityName' not found in database-mapping.json"
    }

    [bool] IsFieldAllowed([string]$entityName, [string]$fieldName) {
        try {
            $tableMapping = $this.GetTableMapping($entityName)
            # "*" wildcard means all fields are allowed
            if ('*' -in $tableMapping.allowedFields) { return $true }
            return $fieldName -in $tableMapping.allowedFields
        } catch {
            return $false
        }
    }

    # Returns the DB column name for a given SQuery field name, applying:
    #   1. Entity-specific override from column-rules.json
    #   2. Resource EntityType column map from resource-columns.json (e.g. DisplayName -> CC)
    #   3. Global renames (e.g. DisplayName -> DisplayName_L1)
    #   4. Auto-rename: FooId -> Foo_Id  (FK naming; skips bare "Id" and already-underscored "_Id")
    [string] GetColumnDbName([string]$entityName, [string]$fieldName) {
        # 1. Entity-specific override from column-rules.json
        if ($this.ColumnRules.entities.ContainsKey($entityName)) {
            $er = $this.ColumnRules.entities[$entityName]
            if ($er.ContainsKey($fieldName) -and $er[$fieldName].ContainsKey('dbColumn')) {
                return $er[$fieldName].dbColumn
            }
        }
        # 2. Resource EntityType column map (has priority over globalRenames for Resource subtypes)
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
        if ($this.ColumnRules.ContainsKey('globalRenames') -and $this.ColumnRules.globalRenames.ContainsKey($fieldName)) {
            return $this.ColumnRules.globalRenames[$fieldName]
        }
        # 4. FK auto-rename: FooId -> Foo_Id (not bare "Id", not already "Foo_Id")
        if ($fieldName -ne 'Id' -and $fieldName.EndsWith('Id') -and -not $fieldName.EndsWith('_Id')) {
            return $fieldName.Substring(0, $fieldName.Length - 2) + '_Id'
        }
        return $fieldName
    }

    # Returns navigation property definition for an entity, or $null if not found.
    # join-patterns.json structure:
    #   { "navigationProperties": { "EntityName": { "NavProp": { targetTable, targetEntity[, localKey][, foreignKey] } } } }
    # FK convention defaults (applied when keys are absent):
    #   localKey  -> "{navPropName}_Id"
    #   foreignKey -> "Id"
    [hashtable] GetNavProp([string]$entityName, [string]$navPropName) {
        if ($null -eq $this.JoinPatterns -or -not $this.JoinPatterns.ContainsKey('navigationProperties')) {
            return $null
        }
        $navProps = $this.JoinPatterns.navigationProperties
        if (-not $navProps.ContainsKey($entityName)) {
            return $null
        }
        $entityNavProps = $navProps[$entityName]
        if (-not $entityNavProps.ContainsKey($navPropName)) {
            return $null
        }
        $raw = $entityNavProps[$navPropName]
        # Apply FK convention defaults if either key is absent (avoids mutating cached config)
        $hasLocal   = $raw.ContainsKey('localKey')
        $hasForeign = $raw.ContainsKey('foreignKey')
        if ($hasLocal -and $hasForeign) { return $raw }
        $result = @{}
        foreach ($k in $raw.Keys) { $result[$k] = $raw[$k] }
        if (-not $hasLocal)   { $result['localKey']   = "${navPropName}_Id" }
        if (-not $hasForeign) { $result['foreignKey'] = 'Id' }
        return $result
    }

    # Returns resource-columns.json config for a Resource EntityType, or $null if not a Resource subtype.
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

    # Helper method to convert PSCustomObject to Hashtable recursively
    [hashtable] ConvertToHashtable([object]$obj) {
        if ($null -eq $obj) {
            return @{}
        }

        $hash = @{}

        $obj.PSObject.Properties | ForEach-Object {
            $key = $_.Name
            $value = $_.Value

            if ($value -is [System.Management.Automation.PSCustomObject]) {
                # Recursively convert nested objects
                $hash[$key] = $this.ConvertToHashtable($value)
            } elseif ($value -is [System.Array]) {
                # Convert arrays, checking each element
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
