# Transformer.ps1
# Transforms QueryAST to SQL with parameterized queries (SECURITY CRITICAL)

# SqlCondition Base Class and Implementations

class SqlCondition {
    [string]$Field
    [string]$Operator
    [object]$Value
    [string]$ParamName

    [string] ToSQL() {
        # Override in derived classes
        throw "ToSQL must be implemented in derived class"
    }
}

class ComparisonCondition : SqlCondition {
    ComparisonCondition([string]$field, [string]$op, [object]$value, [string]$paramName) {
        $this.Field = $field
        $this.Operator = $op
        $this.Value = $value
        $this.ParamName = $paramName
    }

    [string] ToSQL() {
        $sqlOp = switch ($this.Operator) {
            'eq' { '=' }
            'neq' { '!=' }
            'gt' { '>' }
            'ge' { '>=' }
            'lt' { '<' }
            'le' { '<=' }
            default { '=' }
        }
        return "$($this.Field) $sqlOp @$($this.ParamName)"
    }
}

class LikeCondition : SqlCondition {
    LikeCondition([string]$field, [string]$op, [string]$value, [string]$paramName) {
        $this.Field = $field
        $this.Operator = $op
        $this.Value = $value
        $this.ParamName = $paramName
    }

    [string] ToSQL() {
        return "$($this.Field) LIKE @$($this.ParamName)"
    }

    [string] GetPatternValue() {
        $pattern = switch ($this.Operator) {
            'contains' { "%$($this.Value)%" }
            'startswith' { "$($this.Value)%" }
            'endswith' { "%$($this.Value)" }
            'like' { $this.Value }  # User provides pattern
            default { $this.Value }
        }
        return $pattern
    }
}

class InCondition : SqlCondition {
    InCondition([string]$field, [string]$op, [array]$values, [string]$paramName) {
        $this.Field = $field
        $this.Operator = $op
        $this.Value = $values
        $this.ParamName = $paramName
    }

    [string] ToSQL() {
        $paramList = @()
        for ($i = 0; $i -lt $this.Value.Count; $i++) {
            $paramList += "@$($this.ParamName)$i"
        }
        $params = $paramList -join ', '

        if ($this.Operator -eq 'notin') {
            return "$($this.Field) NOT IN ($params)"
        }
        return "$($this.Field) IN ($params)"
    }
}

class NullCondition : SqlCondition {
    NullCondition([string]$field, [string]$op) {
        $this.Field = $field
        $this.Operator = $op
        $this.ParamName = $null  # No parameter needed for NULL checks
    }

    [string] ToSQL() {
        if ($this.Operator -eq 'isnotnull') {
            return "$($this.Field) IS NOT NULL"
        }
        return "$($this.Field) IS NULL"
    }
}

# SQL Query Builder with Fluent API

class SqlQueryBuilder {
    [string[]]$SelectFields
    [string]$TableName
    [string]$TableAlias
    [SqlCondition[]]$WhereConditions
    [hashtable]$SortFields
    [int]$LimitValue
    [int]$OffsetValue
    [hashtable]$Parameters
    [int]$ParamCounter

    SqlQueryBuilder() {
        $this.SelectFields = @()
        $this.WhereConditions = @()
        $this.SortFields = @{}
        $this.Parameters = @{}
        $this.ParamCounter = 0
        $this.TableAlias = 'r'  # Default alias
        $this.LimitValue = 0
        $this.OffsetValue = 0
    }

    [SqlQueryBuilder] AddSelect([string[]]$fields) {
        $this.SelectFields = $fields
        return $this
    }

    [SqlQueryBuilder] FromTable([string]$table, [string]$alias) {
        $this.TableName = $table
        $this.TableAlias = $alias
        return $this
    }

    [SqlQueryBuilder] AddWhere([SqlCondition]$condition) {
        $this.WhereConditions += $condition
        return $this
    }

    [SqlQueryBuilder] AddOrderBy([string]$field, [string]$direction) {
        $this.SortFields[$field] = $direction
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

    [string] GetNextParamName() {
        $this.ParamCounter++
        return "p$($this.ParamCounter)"
    }

    [hashtable] Build() {
        # SELECT clause
        $selectClause = if ($this.SelectFields.Count -gt 0) {
            "SELECT " + ($this.SelectFields -join ', ')
        } else {
            "SELECT *"
        }

        # FROM clause
        $fromClause = "FROM $($this.TableName) $($this.TableAlias)"

        # WHERE clause
        $whereClause = ""
        if ($this.WhereConditions.Count -gt 0) {
            $whereParts = @()
            foreach ($condition in $this.WhereConditions) {
                $whereParts += $condition.ToSQL()

                # Add parameters
                if ($condition.ParamName) {
                    if ($condition -is [InCondition]) {
                        # Handle IN conditions with multiple parameters
                        for ($i = 0; $i -lt $condition.Value.Count; $i++) {
                            $this.Parameters["$($condition.ParamName)$i"] = $condition.Value[$i]
                        }
                    } elseif ($condition -is [LikeCondition]) {
                        # Handle LIKE conditions with pattern transformation
                        $this.Parameters[$condition.ParamName] = $condition.GetPatternValue()
                    } else {
                        $this.Parameters[$condition.ParamName] = $condition.Value
                    }
                }
            }
            $whereClause = "WHERE " + ($whereParts -join ' AND ')
        }

        # ORDER BY clause
        $orderClause = ""
        if ($this.SortFields.Count -gt 0) {
            $orderParts = @()
            foreach ($field in $this.SortFields.Keys) {
                $direction = $this.SortFields[$field]
                $orderParts += "$field $direction"
            }
            $orderClause = "ORDER BY " + ($orderParts -join ', ')
        }

        # LIMIT/OFFSET clause (using OFFSET-FETCH for SQL Server)
        $limitClause = ""
        if ($this.OffsetValue -gt 0 -or $this.LimitValue -gt 0) {
            # SQL Server requires ORDER BY for OFFSET-FETCH
            if ($this.SortFields.Count -eq 0) {
                # Add a default sort if none specified
                $orderClause = "ORDER BY (SELECT NULL)"
            }

            $limitClause = "OFFSET $($this.OffsetValue) ROWS"
            if ($this.LimitValue -gt 0) {
                $limitClause += " FETCH NEXT $($this.LimitValue) ROWS ONLY"
            }
        }

        # Build final query
        $queryParts = @($selectClause, $fromClause, $whereClause, $orderClause, $limitClause) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $query = $queryParts -join "`n"

        return @{
            Query = $query
            Parameters = $this.Parameters
        }
    }
}

# Transformer Class

class SQueryTransformer {
    [object]$AST
    [object]$Config

    SQueryTransformer([object]$ast, [object]$config) {
        $this.AST = $ast
        $this.Config = $config
    }

    [SqlQueryBuilder] Transform() {
        $builder = [SqlQueryBuilder]::new()

        # Get table mapping
        $tableMapping = $this.Config.GetTableMapping($this.AST.RootEntity)
        $builder.FromTable($tableMapping.tableName, $tableMapping.alias)

        # Transform SELECT
        if ($this.AST.Select.Count -gt 0) {
            $selectFields = $this.TransformSelect()
            $builder.AddSelect($selectFields)
        } else {
            # Use default fields if specified in config
            $defaultFields = $this.Config.GetDefaultFields($this.AST.RootEntity)
            if ($defaultFields.Count -gt 0) {
                $transformedDefaults = $this.TransformFieldNames($defaultFields, $tableMapping.alias)
                $builder.AddSelect($transformedDefaults)
            }
        }

        # Transform WHERE conditions
        foreach ($filterNode in $this.AST.Filters) {
            $condition = $this.TransformFilter($filterNode, $builder)
            $builder.AddWhere($condition)
        }

        # Transform ORDER BY
        foreach ($sortNode in $this.AST.Sort) {
            $dbField = $this.TransformFieldName($sortNode.Field, $tableMapping.alias)
            $builder.AddOrderBy($dbField, $sortNode.Direction.ToUpper())
        }

        # Transform LIMIT/OFFSET
        if ($this.AST.Page) {
            if ($this.AST.Page.Limit -gt 0) {
                $builder.SetLimit($this.AST.Page.Limit)
            }
            if ($this.AST.Page.Offset -gt 0) {
                $builder.SetOffset($this.AST.Page.Offset)
            }
        }

        return $builder
    }

    [string[]] TransformSelect() {
        $tableMapping = $this.Config.GetTableMapping($this.AST.RootEntity)
        $alias = $tableMapping.alias
        $fields = @()

        foreach ($selectNode in $this.AST.Select) {
            foreach ($field in $selectNode.Fields) {
                $fields += $this.TransformFieldName($field, $alias)
            }
        }

        return $fields
    }

    [string] TransformFieldName([string]$apiFieldName, [string]$alias) {
        $columnMapping = $this.Config.GetColumnMapping($this.AST.RootEntity, $apiFieldName)
        return "$alias.$($columnMapping.dbColumn)"
    }

    [string[]] TransformFieldNames([string[]]$apiFieldNames, [string]$alias) {
        $result = @()
        foreach ($fieldName in $apiFieldNames) {
            $result += $this.TransformFieldName($fieldName, $alias)
        }
        return $result
    }

    [SqlCondition] TransformFilter([object]$filterNode, [SqlQueryBuilder]$builder) {
        $tableMapping = $this.Config.GetTableMapping($this.AST.RootEntity)
        $dbField = $this.TransformFieldName($filterNode.Field, $tableMapping.alias)
        $operatorMapping = $this.Config.GetOperatorMapping($filterNode.Operator)
        $paramName = $builder.GetNextParamName()

        # Create appropriate condition based on operator type
        $condition = switch ($operatorMapping.conditionType) {
            'comparison' {
                [ComparisonCondition]::new($dbField, $filterNode.Operator, $filterNode.Value, $paramName)
            }
            'pattern' {
                [LikeCondition]::new($dbField, $filterNode.Operator, $filterNode.Value, $paramName)
            }
            'set' {
                [InCondition]::new($dbField, $filterNode.Operator, $filterNode.Value, $paramName)
            }
            'null' {
                [NullCondition]::new($dbField, $filterNode.Operator)
            }
            default {
                throw "Unknown condition type: $($operatorMapping.conditionType)"
            }
        }

        return $condition
    }
}
