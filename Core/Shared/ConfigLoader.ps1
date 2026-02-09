# ConfigLoader.ps1
# Loads and validates JSON configuration files for SQuery-SQL-Translator

class ConfigLoader {
    [hashtable]$DatabaseMapping
    [hashtable]$ColumnRules
    [hashtable]$Operators
    [hashtable]$JoinPatterns
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

            # Join patterns optional for Phase 1
            $joinPatternsPath = Join-Path $this.ConfigPath "join-patterns.json"
            if (Test-Path $joinPatternsPath) {
                $joinPatternsJson = Get-Content $joinPatternsPath -Raw | ConvertFrom-Json
                $this.JoinPatterns = $this.ConvertToHashtable($joinPatternsJson)
            } else {
                $this.JoinPatterns = @{}
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

        # Cross-validate: ensure all entities in column-rules exist in database-mapping
        foreach ($entity in $this.ColumnRules.entities.Keys) {
            if (-not $this.DatabaseMapping.tables.ContainsKey($entity)) {
                throw "Entity '$entity' in column-rules.json not found in database-mapping.json"
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
        throw "Entity '$entityName' not found in database-mapping.json"
    }

    [hashtable] GetColumnMapping([string]$entityName, [string]$fieldName) {
        if ($this.ColumnRules.entities.ContainsKey($entityName)) {
            $entity = $this.ColumnRules.entities[$entityName]
            if ($entity.ContainsKey($fieldName)) {
                return $entity[$fieldName]
            }
        }
        throw "Field '$fieldName' not found for entity '$entityName' in column-rules.json"
    }

    [hashtable] GetOperatorMapping([string]$operatorName) {
        if ($this.Operators.operators.ContainsKey($operatorName)) {
            return $this.Operators.operators[$operatorName]
        }
        throw "Operator '$operatorName' not found in operator.json"
    }

    [bool] IsFieldAllowed([string]$entityName, [string]$fieldName) {
        try {
            $tableMapping = $this.GetTableMapping($entityName)
            return $fieldName -in $tableMapping.allowedFields
        } catch {
            return $false
        }
    }

    [bool] IsOperatorAllowedForField([string]$entityName, [string]$fieldName, [string]$operator) {
        try {
            $columnMapping = $this.GetColumnMapping($entityName, $fieldName)
            return $operator -in $columnMapping.allowedOperators
        } catch {
            return $false
        }
    }

    [string[]] GetAllowedFields([string]$entityName) {
        try {
            $tableMapping = $this.GetTableMapping($entityName)
            return $tableMapping.allowedFields
        } catch {
            return @()
        }
    }

    [string[]] GetDefaultFields([string]$entityName) {
        try {
            $tableMapping = $this.GetTableMapping($entityName)
            if ($tableMapping.ContainsKey('defaultFields')) {
                return $tableMapping.defaultFields
            }
            return @()
        } catch {
            return @()
        }
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
