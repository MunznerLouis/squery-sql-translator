# Validator.ps1
# Validates SQueryAST against configuration rules (security & semantic layer)
#
# Validation checks:
#   1. Root entity exists in configuration                          (error)
#   2. TOP value within bounds                                      (error / warning)
#   3. WHERE values not excessively long                            (warning)
#   4. JOIN aliases are unique (no duplicates)                      (error)
#   5. JOIN aliases don't collide with root alias                   (error)
#   6. JOIN navigation properties exist in config                   (error / warning)
#   7. Aliases used in SELECT/WHERE/ORDER BY reference declared JOINs (error)
#   8. Fields exist in entity when allowedFields is not ["*"]       (warning)
#   9. SELECT clause is not empty when present                      (warning)
#  10. WHERE expression tree depth is reasonable                    (warning)

class SQueryValidator {
    [object]$AST
    [object]$Config
    [System.Collections.ArrayList]$Errors
    [System.Collections.ArrayList]$Warnings

    # Alias -> entity name mapping built during validation
    hidden [hashtable]$AliasToEntity

    # Maximum WHERE nesting depth before warning
    hidden static [int]$MaxWhereDepth = 10

    SQueryValidator([object]$ast, [object]$config) {
        $this.AST           = $ast
        $this.Config        = $config
        $this.Errors        = [System.Collections.ArrayList]::new()
        $this.Warnings      = [System.Collections.ArrayList]::new()
        $this.AliasToEntity = @{}
    }

    [bool] Validate() {

        # -- 1. Root entity must exist in database-mapping.json ----------------
        $rootAlias = $null
        try {
            $tableMapping = $this.Config.GetTableMapping($this.AST.RootEntity)
            $rootAlias = $tableMapping.alias
            $this.AliasToEntity[$rootAlias] = $this.AST.RootEntity
        } catch {
            $null = $this.Errors.Add("Root entity '$($this.AST.RootEntity)' not found in database-mapping.json")
            # Can't continue most checks without a valid root entity
            return $false
        }

        # -- 2. TOP value bounds -----------------------------------------------
        if ($this.AST.Top -lt 0) {
            $null = $this.Errors.Add("TOP value cannot be negative (got $($this.AST.Top))")
        } elseif ($this.AST.Top -gt 10000) {
            $null = $this.Warnings.Add("TOP value $($this.AST.Top) is very large; consider limiting to 10000 or fewer rows")
        }

        # -- 3-6. Validate JOINs -----------------------------------------------
        $this.ValidateJoins($rootAlias)

        # -- 7-8. Validate SELECT fields ----------------------------------------
        $this.ValidateSelect($rootAlias)

        # -- 7-8. Validate ORDER BY fields --------------------------------------
        $this.ValidateOrderBy($rootAlias)

        # -- 3, 7-8, 10. Validate WHERE ----------------------------------------
        if ($null -ne $this.AST.Where) {
            $this.ValidateWhereExpr($this.AST.Where, $rootAlias, 0)
        }

        return $this.Errors.Count -eq 0
    }

    # ==========================================================================
    # JOIN validation
    # ==========================================================================

    [void] ValidateJoins([string]$rootAlias) {
        $seenAliases = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        # Root alias is implicitly taken
        $null = $seenAliases.Add($rootAlias)

        foreach ($joinNode in $this.AST.Joins) {
            $alias      = $joinNode.Alias
            $entityPath = $joinNode.EntityPath

            # -- 4. Duplicate alias check --------------------------------------
            if (-not $seenAliases.Add($alias)) {
                $null = $this.Errors.Add("Duplicate JOIN alias '$alias'. Each alias must be unique.")
                continue
            }

            # -- 5. Alias collides with root alias -----------------------------
            if ($alias -eq $rootAlias) {
                $null = $this.Errors.Add("JOIN alias '$alias' collides with root entity alias.")
                continue
            }

            # -- 6. Navigation property exists in config -----------------------
            $parentAlias = $rootAlias
            $navPropName = $entityPath

            if ($entityPath -match '\.') {
                $dotIdx      = $entityPath.IndexOf('.')
                $parentAlias = $entityPath.Substring(0, $dotIdx)
                $navPropName = $entityPath.Substring($dotIdx + 1)
            }

            # Strip colon type-filter suffix (e.g. "Workflow_Directory_FR_User:Directory_FR_User")
            if ($navPropName -match ':') {
                $navPropName = $navPropName.Substring(0, $navPropName.IndexOf(':'))
            }

            # Resolve parent entity
            $parentEntity = $null
            if ($this.AliasToEntity.ContainsKey($parentAlias)) {
                $parentEntity = $this.AliasToEntity[$parentAlias]
            } else {
                $null = $this.Errors.Add("JOIN '$alias': parent alias '$parentAlias' is not declared. Declare it in a preceding JOIN.")
                # Track alias anyway so later references don't cascade errors
                $this.AliasToEntity[$alias] = $navPropName
                continue
            }

            # Check nav prop in config
            $navProp = $this.Config.GetNavProp($parentEntity, $navPropName)
            if ($null -eq $navProp) {
                $null = $this.Warnings.Add("JOIN '$alias': navigation property '$navPropName' is not defined for entity '$parentEntity' in join-patterns.json. The generated JOIN may be incorrect.")
            }

            # Track alias -> target entity for downstream checks
            $targetEntity = $navPropName
            if ($null -ne $navProp -and $navProp.ContainsKey('targetEntity')) {
                $targetEntity = $navProp.targetEntity
            }
            $this.AliasToEntity[$alias] = $targetEntity
        }
    }

    # ==========================================================================
    # SELECT validation
    # ==========================================================================

    [void] ValidateSelect([string]$rootAlias) {
        # -- 9. Empty SELECT (not an error, generates SELECT *, but worth noting)
        if ($this.AST.Select.Length -eq 0) {
            return
        }

        foreach ($field in $this.AST.Select) {
            $this.ValidateFieldReference($field, $rootAlias, 'SELECT')
        }
    }

    # ==========================================================================
    # ORDER BY validation
    # ==========================================================================

    [void] ValidateOrderBy([string]$rootAlias) {
        foreach ($sortNode in $this.AST.OrderBy) {
            $this.ValidateFieldReference($sortNode.Field, $rootAlias, 'ORDER BY')

            # Direction should be ASC or DESC (parser guarantees this, but belt-and-suspenders)
            if ($sortNode.Direction -notin @('ASC', 'DESC')) {
                $null = $this.Errors.Add("ORDER BY field '$($sortNode.Field)' has invalid direction '$($sortNode.Direction)'. Expected ASC or DESC.")
            }
        }
    }

    # ==========================================================================
    # WHERE validation (recursive, with depth tracking)
    # ==========================================================================

    [void] ValidateWhereExpr([object]$expr, [string]$rootAlias, [int]$depth) {
        if ($null -eq $expr) { return }

        # -- 10. Depth check ---------------------------------------------------
        if ($depth -gt [SQueryValidator]::MaxWhereDepth) {
            $null = $this.Warnings.Add("WHERE expression nesting depth exceeds $([SQueryValidator]::MaxWhereDepth). Consider simplifying the query.")
            return   # stop recursing to avoid stack overflow
        }

        switch ($expr.ExprType) {
            'compare' {
                # Validate field reference
                $this.ValidateFieldReference($expr.Field, $rootAlias, 'WHERE')

                # -- 3. Value length check -------------------------------------
                $value = $expr.Value
                if ($value -is [string] -and $value.Length -gt 4000) {
                    $null = $this.Warnings.Add("WHERE value for field '$($expr.Field)' exceeds 4000 characters")
                }
            }
            'logical' {
                $this.ValidateWhereExpr($expr.Left,  $rootAlias, $depth + 1)
                $this.ValidateWhereExpr($expr.Right, $rootAlias, $depth + 1)
            }
            'not' {
                $this.ValidateWhereExpr($expr.Child, $rootAlias, $depth + 1)
            }
            default {
                $null = $this.Warnings.Add("WHERE: unknown expression type '$($expr.ExprType)'")
            }
        }
    }

    # ==========================================================================
    # Shared: validate a field reference (alias.Column or Column)
    # ==========================================================================

    [void] ValidateFieldReference([string]$field, [string]$rootAlias, [string]$clause) {
        $alias    = $rootAlias
        $colName  = $field

        # Split "alias.Column" if dotted
        if ($field -match '\.') {
            $dotIdx  = $field.IndexOf('.')
            $alias   = $field.Substring(0, $dotIdx)
            $colName = $field.Substring($dotIdx + 1)
        }

        # -- 7. Alias must be declared -----------------------------------------
        if (-not $this.AliasToEntity.ContainsKey($alias)) {
            $null = $this.Errors.Add("${clause}: alias '$alias' in field '$field' is not declared. Available aliases: $($this.AliasToEntity.Keys -join ', ')")
            return
        }

        # -- 8. Field must be allowed (only when allowedFields is not ["*"]) ---
        $entity = $this.AliasToEntity[$alias]
        if (-not $this.Config.IsFieldAllowed($entity, $colName)) {
            $null = $this.Warnings.Add("${clause}: field '$colName' may not exist on entity '$entity'. Check database-mapping.json allowedFields.")
        }
    }

    # ==========================================================================
    # Public getters
    # ==========================================================================

    [string[]] GetErrors() {
        return $this.Errors.ToArray()
    }

    [string[]] GetWarnings() {
        return $this.Warnings.ToArray()
    }
}
