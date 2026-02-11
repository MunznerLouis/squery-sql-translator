# Validator.ps1
# Validates SQueryAST against configuration rules (security layer)
#
# With the SQL-like SQuery format, field names include alias prefixes (r.DisplayName)
# and JOINs are resolved at transform time. Validation here focuses on:
#   1. Root entity exists in configuration (hard error)
#   2. TOP value is within reasonable bounds (warning)
#   3. WHERE values are not excessively long (warning)

class SQueryValidator {
    [object]$AST
    [object]$Config
    [System.Collections.ArrayList]$Errors
    [System.Collections.ArrayList]$Warnings

    SQueryValidator([object]$ast, [object]$config) {
        $this.AST      = $ast
        $this.Config   = $config
        $this.Errors   = [System.Collections.ArrayList]::new()
        $this.Warnings = [System.Collections.ArrayList]::new()
    }

    [bool] Validate() {
        # 1. Root entity must be registered in database-mapping.json
        try {
            $null = $this.Config.GetTableMapping($this.AST.RootEntity)
        } catch {
            $null = $this.Errors.Add("Root entity '$($this.AST.RootEntity)' not found in database-mapping.json")
            return $false
        }

        # 2. TOP value bounds check
        if ($this.AST.Top -lt 0) {
            $null = $this.Errors.Add("TOP value cannot be negative (got $($this.AST.Top))")
        } elseif ($this.AST.Top -gt 10000) {
            $null = $this.Warnings.Add("TOP value $($this.AST.Top) is very large; consider limiting to 10000 or fewer rows")
        }

        # 3. Validate WHERE expression values (no extremely long strings)
        if ($null -ne $this.AST.Where) {
            $this.ValidateWhereExpr($this.AST.Where)
        }

        return $this.Errors.Count -eq 0
    }

    [void] ValidateWhereExpr([object]$expr) {
        if ($null -eq $expr) { return }

        switch ($expr.ExprType) {
            'compare' {
                $value = $expr.Value
                if ($value -is [string] -and $value.Length -gt 4000) {
                    $null = $this.Warnings.Add("WHERE value for field '$($expr.Field)' exceeds 4000 characters")
                }
            }
            'logical' {
                $this.ValidateWhereExpr($expr.Left)
                $this.ValidateWhereExpr($expr.Right)
            }
            'not' {
                $this.ValidateWhereExpr($expr.Child)
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
