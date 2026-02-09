# Validator.ps1
# Validates QueryAST against configuration rules (security layer)

class SQueryValidator {
    [object]$AST
    [object]$Config
    [System.Collections.ArrayList]$Errors
    [System.Collections.ArrayList]$Warnings

    SQueryValidator([object]$ast, [object]$config) {
        $this.AST = $ast
        $this.Config = $config
        $this.Errors = [System.Collections.ArrayList]::new()
        $this.Warnings = [System.Collections.ArrayList]::new()
    }

    [bool] Validate() {
        # Validate entity exists
        try {
            $null = $this.Config.GetTableMapping($this.AST.RootEntity)
        } catch {
            $this.Errors.Add("Root entity '$($this.AST.RootEntity)' not found in configuration") | Out-Null
            return $false
        }

        # Validate SELECT fields
        foreach ($selectNode in $this.AST.Select) {
            foreach ($field in $selectNode.Fields) {
                if (-not $this.Config.IsFieldAllowed($this.AST.RootEntity, $field)) {
                    $this.Errors.Add("Field '$field' is not allowed for entity '$($this.AST.RootEntity)'") | Out-Null
                }
            }
        }

        # Validate FILTER conditions
        foreach ($filterNode in $this.AST.Filters) {
            # Check field exists and is allowed
            if (-not $this.Config.IsFieldAllowed($this.AST.RootEntity, $filterNode.Field)) {
                $this.Errors.Add("Filter field '$($filterNode.Field)' is not allowed for entity '$($this.AST.RootEntity)'") | Out-Null
                continue
            }

            # Check operator is valid
            try {
                $null = $this.Config.GetOperatorMapping($filterNode.Operator)
            } catch {
                $this.Errors.Add("Operator '$($filterNode.Operator)' is not a valid operator") | Out-Null
                continue
            }

            # Check operator is allowed for this field
            if (-not $this.Config.IsOperatorAllowedForField($this.AST.RootEntity, $filterNode.Field, $filterNode.Operator)) {
                $this.Errors.Add("Operator '$($filterNode.Operator)' is not allowed for field '$($filterNode.Field)'") | Out-Null
            }

            # Validate value types
            try {
                $columnMapping = $this.Config.GetColumnMapping($this.AST.RootEntity, $filterNode.Field)
                $this.ValidateValueType($filterNode, $columnMapping)
            } catch {
                # Column mapping not found - already reported above
            }
        }

        # Validate SORT fields
        foreach ($sortNode in $this.AST.Sort) {
            if (-not $this.Config.IsFieldAllowed($this.AST.RootEntity, $sortNode.Field)) {
                $this.Errors.Add("Sort field '$($sortNode.Field)' is not allowed for entity '$($this.AST.RootEntity)'") | Out-Null
            }
        }

        # Validate PAGE limits (reasonable bounds)
        if ($this.AST.Page) {
            if ($this.AST.Page.Limit -lt 0 -or $this.AST.Page.Limit -gt 1000) {
                $this.Warnings.Add("Page limit should be between 0 and 1000, got $($this.AST.Page.Limit)") | Out-Null
            }
            if ($this.AST.Page.Offset -lt 0) {
                $this.Errors.Add("Page offset cannot be negative") | Out-Null
            }
        }

        return $this.Errors.Count -eq 0
    }

    [void] ValidateValueType([object]$filter, [hashtable]$columnMapping) {
        if (-not $columnMapping.ContainsKey('dataType')) {
            return
        }

        $dataType = $columnMapping.dataType
        $value = $filter.Value

        switch ($dataType) {
            'int' {
                $this.ValidateIntegerValue($filter.Field, $value)
            }
            'decimal' {
                $this.ValidateDecimalValue($filter.Field, $value)
            }
            'datetime' {
                $this.ValidateDateTimeValue($filter.Field, $value)
            }
            'bit' {
                $this.ValidateBooleanValue($filter.Field, $value)
            }
            'nvarchar' {
                $this.ValidateStringValue($filter.Field, $value, $columnMapping)
            }
        }
    }

    [void] ValidateIntegerValue([string]$fieldName, [object]$value) {
        if ($value -is [array]) {
            foreach ($v in $value) {
                if (-not ($v -match '^\-?\d+$')) {
                    $this.Errors.Add("Value '$v' for field '$fieldName' must be an integer") | Out-Null
                }
            }
        } else {
            if (-not ($value -match '^\-?\d+$')) {
                $this.Errors.Add("Value '$value' for field '$fieldName' must be an integer") | Out-Null
            }
        }
    }

    [void] ValidateDecimalValue([string]$fieldName, [object]$value) {
        if ($value -is [array]) {
            foreach ($v in $value) {
                if (-not ($v -match '^\-?\d+(\.\d+)?$')) {
                    $this.Errors.Add("Value '$v' for field '$fieldName' must be a decimal number") | Out-Null
                }
            }
        } else {
            if (-not ($value -match '^\-?\d+(\.\d+)?$')) {
                $this.Errors.Add("Value '$value' for field '$fieldName' must be a decimal number") | Out-Null
            }
        }
    }

    [void] ValidateDateTimeValue([string]$fieldName, [object]$value) {
        if ($value -is [array]) {
            foreach ($v in $value) {
                try {
                    $null = [datetime]::Parse($v)
                } catch {
                    $this.Errors.Add("Value '$v' for field '$fieldName' must be a valid datetime") | Out-Null
                }
            }
        } else {
            try {
                $null = [datetime]::Parse($value)
            } catch {
                $this.Errors.Add("Value '$value' for field '$fieldName' must be a valid datetime") | Out-Null
            }
        }
    }

    [void] ValidateBooleanValue([string]$fieldName, [object]$value) {
        $validValues = @('0', '1', 'true', 'false', 'True', 'False', 'TRUE', 'FALSE')

        if ($value -is [array]) {
            foreach ($v in $value) {
                if ($v -notin $validValues) {
                    $this.Errors.Add("Value '$v' for field '$fieldName' must be a boolean (0, 1, true, false)") | Out-Null
                }
            }
        } else {
            if ($value -notin $validValues) {
                $this.Errors.Add("Value '$value' for field '$fieldName' must be a boolean (0, 1, true, false)") | Out-Null
            }
        }
    }

    [void] ValidateStringValue([string]$fieldName, [object]$value, [hashtable]$columnMapping) {
        if (-not $columnMapping.ContainsKey('maxLength')) {
            return
        }

        $maxLength = $columnMapping.maxLength

        if ($value -is [array]) {
            foreach ($v in $value) {
                if ($v.Length -gt $maxLength) {
                    $this.Warnings.Add("Value for field '$fieldName' exceeds maximum length of $maxLength characters") | Out-Null
                }
            }
        } else {
            if ($value -is [string] -and $value.Length -gt $maxLength) {
                $this.Warnings.Add("Value for field '$fieldName' exceeds maximum length of $maxLength characters") | Out-Null
            }
        }
    }

    [string[]] GetErrors() {
        return $this.Errors.ToArray()
    }

    [string[]] GetWarnings() {
        return $this.Warnings.ToArray()
    }
}
