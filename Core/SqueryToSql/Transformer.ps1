# Transformer.ps1
# Transforms SQueryAST to parameterized SQL (SECURITY CRITICAL - all values parameterized)

# -- SQL Query Builder ----------------------------------------------------------
# Fluent builder that assembles SELECT / FROM / JOIN / WHERE / ORDER BY / LIMIT

class SqlQueryBuilder {
    [string[]]$SelectFields
    [string]$TableName
    [string]$TableAlias
    [System.Collections.ArrayList]$JoinClauses    # pre-built JOIN SQL strings
    [string]$WhereSQL                             # pre-built WHERE SQL fragment
    [System.Collections.ArrayList]$OrderFields   # @{Field; Direction} ordered list
    [int]$TopValue                                # for SELECT TOP N
    [int]$LimitValue                              # for OFFSET/FETCH
    [int]$OffsetValue
    [hashtable]$Parameters

    SqlQueryBuilder() {
        $this.SelectFields = @()
        $this.JoinClauses  = [System.Collections.ArrayList]::new()
        $this.OrderFields  = [System.Collections.ArrayList]::new()
        $this.TopValue     = 0
        $this.LimitValue   = 0
        $this.OffsetValue  = 0
        $this.Parameters   = @{}
    }

    [SqlQueryBuilder] AddSelect([string[]]$fields) {
        $this.SelectFields = $fields
        return $this
    }

    [SqlQueryBuilder] FromTable([string]$table, [string]$alias) {
        $this.TableName  = $table
        $this.TableAlias = $alias
        return $this
    }

    [SqlQueryBuilder] AddJoin([string]$joinSql) {
        $null = $this.JoinClauses.Add($joinSql)
        return $this
    }

    [SqlQueryBuilder] SetWhere([string]$whereSql) {
        $this.WhereSQL = $whereSql
        return $this
    }

    [SqlQueryBuilder] AddOrderBy([string]$field, [string]$direction) {
        $null = $this.OrderFields.Add(@{ Field = $field; Direction = $direction })
        return $this
    }

    [SqlQueryBuilder] SetTop([int]$top) {
        $this.TopValue = $top
        return $this
    }

    [SqlQueryBuilder] SetLimit([int]$limit) {
        $this.LimitValue = $limit
        return $this
    }

    [SqlQueryBuilder] SetOffset([int]$offset) {
        $this.OffsetValue = $offset
        return $this
    }

    [hashtable] Build() {
        # SELECT clause - TOP N goes here for SQL Server
        $topClause    = if ($this.TopValue -gt 0) { "TOP $($this.TopValue) " } else { "" }
        $selectClause = if ($this.SelectFields.Count -gt 0) {
            "SELECT $topClause" + ($this.SelectFields -join ', ')
        } else {
            "SELECT $($topClause)*"
        }

        # FROM clause
        $fromClause = "FROM $($this.TableName) $($this.TableAlias)"

        # ORDER BY
        $orderClause = ""
        if ($this.OrderFields.Count -gt 0) {
            $orderParts = [System.Collections.ArrayList]::new()
            foreach ($item in $this.OrderFields) {
                $null = $orderParts.Add("$($item.Field) $($item.Direction)")
            }
            $orderClause = "ORDER BY " + ($orderParts.ToArray() -join ', ')
        }

        # OFFSET/FETCH (only when no TOP is set)
        $limitClause = ""
        if ($this.TopValue -eq 0 -and ($this.OffsetValue -gt 0 -or $this.LimitValue -gt 0)) {
            if ([string]::IsNullOrWhiteSpace($orderClause)) {
                $orderClause = "ORDER BY (SELECT NULL)"
            }
            $limitClause = "OFFSET $($this.OffsetValue) ROWS"
            if ($this.LimitValue -gt 0) {
                $limitClause += " FETCH NEXT $($this.LimitValue) ROWS ONLY"
            }
        }

        # Assemble all parts
        $parts = [System.Collections.ArrayList]::new()
        $null = $parts.Add($selectClause)
        $null = $parts.Add($fromClause)
        foreach ($j in $this.JoinClauses) { $null = $parts.Add($j) }
        if (-not [string]::IsNullOrWhiteSpace($this.WhereSQL)) { $null = $parts.Add("WHERE $($this.WhereSQL)") }
        if (-not [string]::IsNullOrWhiteSpace($orderClause))   { $null = $parts.Add($orderClause) }
        if (-not [string]::IsNullOrWhiteSpace($limitClause))   { $null = $parts.Add($limitClause) }

        $query = $parts.ToArray() -join "`n"

        return @{
            Query      = $query
            Parameters = $this.Parameters
        }
    }
}

# -- Transformer ----------------------------------------------------------------
# Walks SQueryAST and populates SqlQueryBuilder, building parameterized SQL

class SQueryTransformer {
    [object]$AST            # SQueryAST
    [object]$Config         # ConfigLoader
    [int]$ParamCounter
    [hashtable]$Parameters
    [hashtable]$AliasToEntity   # alias → entity-name for already-resolved joins

    SQueryTransformer([object]$ast, [object]$config) {
        $this.AST           = $ast
        $this.Config        = $config
        $this.ParamCounter  = 0
        $this.Parameters    = @{}
        $this.AliasToEntity = @{}
    }

    [string] NextParamName() {
        $this.ParamCounter++
        return "p$($this.ParamCounter)"
    }

    # -- Entry point -----------------------------------------------------------

    [SqlQueryBuilder] Transform() {
        $builder = [SqlQueryBuilder]::new()
        $builder.Parameters = $this.Parameters

        # Root entity → FROM
        $tableMapping = $this.Config.GetTableMapping($this.AST.RootEntity)
        $rootAlias    = $tableMapping.alias
        $builder.FromTable($tableMapping.tableName, $rootAlias)

        # Track the root entity alias
        $this.AliasToEntity[$rootAlias] = $this.AST.RootEntity

        # JOINs
        foreach ($joinNode in $this.AST.Joins) {
            $joinSql = $this.TransformJoin($joinNode, $rootAlias)
            if (-not [string]::IsNullOrWhiteSpace($joinSql)) {
                $builder.AddJoin($joinSql)
            }
        }

        # SELECT
        if ($this.AST.Select.Length -gt 0) {
            $selectFields = $this.TransformSelect($rootAlias)
            $builder.AddSelect($selectFields)
        }

        # WHERE
        if ($null -ne $this.AST.Where) {
            $whereSql = $this.TransformWhereExpr($this.AST.Where, $rootAlias)
            $builder.SetWhere($whereSql)
        }

        # ORDER BY
        foreach ($sortNode in $this.AST.OrderBy) {
            $field = $this.ResolveField($sortNode.Field, $rootAlias)
            $builder.AddOrderBy($field, $sortNode.Direction)
        }

        # TOP
        if ($this.AST.Top -gt 0) {
            $builder.SetTop($this.AST.Top)
        }

        return $builder
    }

    # -- JOIN resolution -------------------------------------------------------
    # join EntityPath [of type TypeFilter] alias
    #
    # EntityPath can be:
    #   "Role"                  → nav prop on root entity
    #   "r.Policy"              → nav prop on alias "r"
    #   "Entity:TypeFilter"     → colon-notation typed join (same as "of type")

    [string] TransformJoin([object]$joinNode, [string]$rootAlias) {
        $entityPath  = $joinNode.EntityPath
        $alias       = $joinNode.Alias

        # Resolve parent alias and nav-prop name from the entity path
        $parentAlias = $rootAlias
        $navPropName = $entityPath

        if ($entityPath -match '\.') {
            # Chained: "r.Policy" → parent="r", nav="Policy"
            $dotIdx      = $entityPath.IndexOf('.')
            $parentAlias = $entityPath.Substring(0, $dotIdx)
            $navPropName = $entityPath.Substring($dotIdx + 1)
        }

        # Colon syntax: "Workflow_Directory_FR_User:Directory_FR_User"
        # Strip the type-filter suffix to get the navigation property name
        if ($navPropName -match ':') {
            $navPropName = $navPropName.Substring(0, $navPropName.IndexOf(':'))
        }

        # Resolve parent entity name
        $parentEntity = $this.AST.RootEntity
        if ($this.AliasToEntity.ContainsKey($parentAlias)) {
            $parentEntity = $this.AliasToEntity[$parentAlias]
        }

        # Look up navigation property in config
        $navProp = $this.Config.GetNavProp($parentEntity, $navPropName)
        if ($null -eq $navProp) {
            Write-Warning "SQueryTransformer: no navigation property '$navPropName' defined for entity '$parentEntity' (join alias '$alias')"
            # Track the alias anyway so chained joins can reference it
            $this.AliasToEntity[$alias] = $navPropName
            return $null
        }

        # Build JOIN SQL
        $joinType = if ($navProp.ContainsKey('joinType')) { $navProp.joinType } else { 'LEFT' }
        $joinSql  = "$joinType JOIN $($navProp.targetTable) $alias ON $parentAlias.$($navProp.localKey) = $alias.$($navProp.foreignKey)"

        # Track alias → target entity
        $targetEntity = if ($navProp.ContainsKey('targetEntity')) { $navProp.targetEntity } else { $navPropName }
        $this.AliasToEntity[$alias] = $targetEntity

        return $joinSql
    }

    # -- SELECT ----------------------------------------------------------------
    # All fields go through ResolveField which applies column renaming.

    [string[]] TransformSelect([string]$rootAlias) {
        $result = [System.Collections.ArrayList]::new()
        foreach ($field in $this.AST.Select) {
            $null = $result.Add($this.ResolveField($field, $rootAlias))
        }
        return $result.ToArray()
    }

    # -- Field resolution (with column renaming) --------------------------------
    # Resolves a field reference to "alias.dbColumn", applying:
    #   - entity-specific overrides from column-rules.json
    #   - global renames (DisplayName -> DisplayName_L1, etc.)
    #   - auto-rename: FooId -> Foo_Id  (FK naming convention)

    [string] ResolveField([string]$field, [string]$rootAlias) {
        if ($field -match '\.') {
            $dotIdx = $field.IndexOf('.')
            $alias  = $field.Substring(0, $dotIdx)
            $col    = $field.Substring($dotIdx + 1)
            $entity = if ($this.AliasToEntity.ContainsKey($alias)) { $this.AliasToEntity[$alias] } else { '' }
            $dbCol  = $this.Config.GetColumnDbName($entity, $col)
            return "$alias.$dbCol"
        }
        $entity = if ($this.AliasToEntity.ContainsKey($rootAlias)) { $this.AliasToEntity[$rootAlias] } else { '' }
        $dbCol  = $this.Config.GetColumnDbName($entity, $field)
        return "$rootAlias.$dbCol"
    }

    # -- WHERE tree → SQL ------------------------------------------------------

    [string] TransformWhereExpr([object]$expr, [string]$rootAlias) {
        switch ($expr.ExprType) {
            'compare' {
                return $this.TransformCompareExpr($expr, $rootAlias)
            }
            'logical' {
                $leftSql  = $this.TransformWhereExpr($expr.Left,  $rootAlias)
                $rightSql = $this.TransformWhereExpr($expr.Right, $rootAlias)
                return "($leftSql $($expr.LogOp) $rightSql)"
            }
            'not' {
                $childSql = $this.TransformWhereExpr($expr.Child, $rootAlias)
                return "NOT ($childSql)"
            }
        }
        throw "SQueryTransformer: unknown expression type '$($expr.ExprType)'"
    }

    [string] TransformCompareExpr([object]$expr, [string]$rootAlias) {
        $field = $this.ResolveField($expr.Field, $rootAlias)
        $op    = $expr.Op
        $value = $expr.Value

        # NULL comparisons become IS NULL / IS NOT NULL
        if ($null -eq $value) {
            if ($op -eq '=')  { return "$field IS NULL" }
            if ($op -eq '!=') { return "$field IS NOT NULL" }
            return "$field IS NULL"
        }

        # LIKE/contains operators: %= and %=% -> LIKE '%value%'
        if ($op -eq '%=' -or $op -eq '%=%') {
            $paramName = $this.NextParamName()
            $this.Parameters[$paramName] = '%' + $value.ToString() + '%'
            return "$field LIKE @$paramName"
        }

        # Boolean -> convert to 0/1 for SQL Server bit columns
        if ($value -is [bool]) {
            $sqlValue   = if ($value) { 1 } else { 0 }
            $paramName  = $this.NextParamName()
            $this.Parameters[$paramName] = $sqlValue
            return "$field $op @$paramName"
        }

        # All other values - parameterize to prevent SQL injection
        $paramName = $this.NextParamName()
        $this.Parameters[$paramName] = $value
        return "$field $op @$paramName"
    }
}
