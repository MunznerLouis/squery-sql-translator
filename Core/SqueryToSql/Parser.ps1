# Parser.ps1
# Parses SQuery tokens into an Abstract Syntax Tree (AST)

# AST Node Classes

class SQueryNode {
    [string]$NodeType  # Base class for all AST nodes
}

class SelectNode : SQueryNode {
    [string[]]$Fields  # ['Id', 'Name', 'Email']

    SelectNode([string[]]$fields) {
        $this.NodeType = 'Select'
        $this.Fields = $fields
    }
}

class FilterNode : SQueryNode {
    [string]$Field     # 'Name'
    [string]$Operator  # 'contains'
    [object]$Value     # 'john' or array for IN

    FilterNode([string]$field, [string]$operator, [object]$value) {
        $this.NodeType = 'Filter'
        $this.Field = $field
        $this.Operator = $operator
        $this.Value = $value
    }
}

class SortNode : SQueryNode {
    [string]$Field      # 'CreatedDate'
    [string]$Direction  # 'asc' or 'desc'

    SortNode([string]$field, [string]$direction) {
        $this.NodeType = 'Sort'
        $this.Field = $field
        $this.Direction = $direction
    }
}

class PageNode : SQueryNode {
    [int]$Limit   # 50
    [int]$Offset  # 0

    PageNode([int]$limit, [int]$offset) {
        $this.NodeType = 'Page'
        $this.Limit = $limit
        $this.Offset = $offset
    }
}

class QueryAST {
    [SelectNode[]]$Select      # Array of select nodes
    [FilterNode[]]$Filters     # Array of filter conditions
    [SortNode[]]$Sort          # Array of sort specifications
    [PageNode]$Page            # Single page node
    [string]$RootEntity        # 'User', 'Order', etc.

    QueryAST([string]$rootEntity) {
        $this.RootEntity = $rootEntity
        $this.Select = @()
        $this.Filters = @()
        $this.Sort = @()
        $this.Page = $null
    }

    [string] ToString() {
        $result = "QueryAST for Entity: $($this.RootEntity)`n"
        $result += "  Select: $($this.Select.Count) fields`n"
        $result += "  Filters: $($this.Filters.Count) conditions`n"
        $result += "  Sort: $($this.Sort.Count) orders`n"
        if ($this.Page) {
            $result += "  Page: Limit=$($this.Page.Limit), Offset=$($this.Page.Offset)`n"
        }
        return $result
    }
}

# Parser Class

class SQueryParser {
    [array]$Tokens
    [string]$RootEntity

    SQueryParser([array]$tokens, [string]$rootEntity) {
        $this.Tokens = $tokens
        $this.RootEntity = $rootEntity
    }

    [QueryAST] Parse() {
        $ast = [QueryAST]::new($this.RootEntity)

        # Group tokens by type for easier processing
        $selectTokens = @($this.Tokens | Where-Object { $_.Type -eq 'select' })
        $filterTokens = @($this.Tokens | Where-Object { $_.Type -eq 'filter' })
        $sortTokens = @($this.Tokens | Where-Object { $_.Type -eq 'sort' })
        $limitTokens = @($this.Tokens | Where-Object { $_.Type -eq 'limit' })
        $offsetTokens = @($this.Tokens | Where-Object { $_.Type -eq 'offset' })
        $pageTokens = @($this.Tokens | Where-Object { $_.Type -eq 'page' })

        # Parse SELECT
        if ($selectTokens.Count -gt 0) {
            $ast.Select = $this.ParseSelect($selectTokens)
        }

        # Parse FILTER
        if ($filterTokens.Count -gt 0) {
            $ast.Filters = $this.ParseFilters($filterTokens)
        }

        # Parse SORT
        if ($sortTokens.Count -gt 0) {
            $ast.Sort = $this.ParseSort($sortTokens)
        }

        # Parse PAGINATION
        $ast.Page = $this.ParsePagination($limitTokens, $offsetTokens, $pageTokens)

        return $ast
    }

    [SelectNode[]] ParseSelect([array]$tokens) {
        $selectNodes = @()

        foreach ($token in $tokens) {
            $fields = $token.Value
            if ($fields -is [string]) {
                $fields = @($fields)
            }

            $selectNodes += [SelectNode]::new($fields)
        }

        return $selectNodes
    }

    [FilterNode[]] ParseFilters([array]$tokens) {
        $filterNodes = @()

        foreach ($token in $tokens) {
            $filterNode = [FilterNode]::new(
                $token.NestedKey,
                $token.Operator,
                $token.Value
            )
            $filterNodes += $filterNode
        }

        return $filterNodes
    }

    [SortNode[]] ParseSort([array]$tokens) {
        $sortNodes = @()

        foreach ($token in $tokens) {
            $field = $token.NestedKey
            $direction = $token.Value.ToLower()

            # Validate direction
            if ($direction -notin @('asc', 'desc')) {
                Write-Warning "Invalid sort direction '$direction' for field '$field', defaulting to 'asc'"
                $direction = 'asc'
            }

            $sortNode = [SortNode]::new($field, $direction)
            $sortNodes += $sortNode
        }

        return $sortNodes
    }

    [PageNode] ParsePagination([array]$limitTokens, [array]$offsetTokens, [array]$pageTokens) {
        $limit = 0
        $offset = 0

        # Handle explicit limit/offset parameters
        if ($limitTokens.Count -gt 0) {
            $limitValue = $limitTokens[0].Value
            if ($limitValue -match '^\d+$') {
                $limit = [int]$limitValue
            } else {
                Write-Warning "Invalid limit value '$limitValue', ignoring"
            }
        }

        if ($offsetTokens.Count -gt 0) {
            $offsetValue = $offsetTokens[0].Value
            if ($offsetValue -match '^\d+$') {
                $offset = [int]$offsetValue
            } else {
                Write-Warning "Invalid offset value '$offsetValue', ignoring"
            }
        }

        # Handle page parameter (could be page=1 or page[limit]=50)
        # For now, simple implementation for future expansion
        if ($pageTokens.Count -gt 0) {
            # Future: handle complex page syntax like page[limit]=50&page[offset]=100
        }

        # Only create PageNode if pagination is requested
        if ($limit -gt 0 -or $offset -gt 0) {
            return [PageNode]::new($limit, $offset)
        }

        return $null
    }
}
