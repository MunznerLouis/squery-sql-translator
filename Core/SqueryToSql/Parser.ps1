# Parser.ps1
# Parses SQuery flat token stream into an Abstract Syntax Tree (AST)
#
# Grammar:
#   [join EntityPath [of type TypeFilter] alias]*
#   [top N]?
#   select field1, alias.field2, ...
#   [where expr]?
#   [order by field [asc|desc], ...]?
#
# Where expr:
#   expr    ::= andExpr (OR andExpr)*
#   andExpr ::= notExpr (AND notExpr)*
#   notExpr ::= NOT notExpr | primary
#   primary ::= '(' expr ')' | field op value

# -- Join Node ------------------------------------------------------------------

class JoinNode {
    [string]$EntityPath   # "Role", "r.Policy", "WorkflowInstance.Workflow"
    [string]$TypeFilter   # "Directory_FR_User" from "of type Directory_FR_User" (or $null)
    [string]$Alias        # "r", "rp", "WorkflowInstance"
}

# -- Sort Node ------------------------------------------------------------------

class SortNode {
    [string]$Field
    [string]$Direction    # 'ASC' or 'DESC'
}

# -- Where Expression Nodes -----------------------------------------------------

class WhereExpr {
    [string]$ExprType     # 'compare', 'logical', 'not'
}

class CompareExpr : WhereExpr {
    [string]$Field        # "OwnerType", "r.FullName", "p.Type"
    [string]$Op           # '=', '!=', '>', '<', '>=', '<='
    [object]$Value        # number, string, $null, boolean

    CompareExpr([string]$field, [string]$op, [object]$value) {
        $this.ExprType = 'compare'
        $this.Field    = $field
        $this.Op       = $op
        $this.Value    = $value
    }
}

class LogicalExpr : WhereExpr {
    [object]$Left         # WhereExpr
    [string]$LogOp        # 'AND' or 'OR'
    [object]$Right        # WhereExpr

    LogicalExpr([object]$left, [string]$logOp, [object]$right) {
        $this.ExprType = 'logical'
        $this.Left     = $left
        $this.LogOp    = $logOp
        $this.Right    = $right
    }
}

class NotExpr : WhereExpr {
    [object]$Child        # WhereExpr

    NotExpr([object]$child) {
        $this.ExprType = 'not'
        $this.Child    = $child
    }
}

# -- Main AST -------------------------------------------------------------------

class SQueryAST {
    [string]$RootEntity
    [System.Collections.ArrayList]$Joins
    [int]$Top                           # 0 = no TOP clause
    [string[]]$Select
    [object]$Where                      # WhereExpr tree or $null
    [System.Collections.ArrayList]$OrderBy

    SQueryAST([string]$rootEntity) {
        $this.RootEntity = $rootEntity
        $this.Joins      = [System.Collections.ArrayList]::new()
        $this.Top        = 0
        $this.Select     = @()
        $this.Where      = $null
        $this.OrderBy    = [System.Collections.ArrayList]::new()
    }

    [string] ToString() {
        $whereStr = if ($this.Where) { 'yes' } else { 'none' }
        return "SQueryAST[$($this.RootEntity)] joins=$($this.Joins.Count) top=$($this.Top) select=$($this.Select.Length) where=$whereStr orderby=$($this.OrderBy.Count)"
    }
}

# -- Parser ---------------------------------------------------------------------

class SQueryParser {
    [array]$Tokens
    [int]$Pos
    [string]$RootEntity

    # Keywords that start a new top-level clause - stop field list parsing when seen
    hidden static [string[]]$ClauseKeywords = @('join', 'top', 'select', 'where', 'order')

    SQueryParser([array]$tokens, [string]$rootEntity) {
        $this.Tokens     = $tokens
        $this.Pos        = 0
        $this.RootEntity = $rootEntity
    }

    # -- Token helpers ---------------------------------------------------------

    [bool] HasTokens() {
        return $this.Pos -lt $this.Tokens.Length
    }

    [object] Peek() {
        if ($this.Pos -lt $this.Tokens.Length) { return $this.Tokens[$this.Pos] }
        return $null
    }

    [object] Consume() {
        if ($this.Pos -lt $this.Tokens.Length) {
            $tok = $this.Tokens[$this.Pos]
            $this.Pos++
            return $tok
        }
        return $null
    }

    [bool] IsKeyword([string]$kw) {
        $tok = $this.Peek()
        return ($null -ne $tok -and $tok.Type -eq 'KEYWORD' -and $tok.Value -eq $kw)
    }

    [bool] IsType([string]$type) {
        $tok = $this.Peek()
        return ($null -ne $tok -and $tok.Type -eq $type)
    }

    [bool] IsClauseKeyword() {
        $tok = $this.Peek()
        return ($null -ne $tok -and $tok.Type -eq 'KEYWORD' -and $tok.Value -in [SQueryParser]::ClauseKeywords)
    }

    [void] ExpectKeyword([string]$kw) {
        $tok = $this.Consume()
        if ($null -eq $tok -or $tok.Type -ne 'KEYWORD' -or $tok.Value -ne $kw) {
            $got = if ($tok) { $tok.Value } else { 'EOF' }
            throw "SQueryParser: expected keyword '$kw' but got '$got'"
        }
    }

    # -- Main parse ------------------------------------------------------------

    [object] Parse() {
        $ast = [SQueryAST]::new($this.RootEntity)

        while ($this.HasTokens()) {
            $tok = $this.Peek()

            if ($tok.Type -ne 'KEYWORD') {
                Write-Warning "Parser: unexpected token '$($tok.Value)' (type=$($tok.Type)) at position $($tok.Position). Expected a keyword (join, select, where, order, top). This token was skipped."
                $this.Consume()
                continue
            }

            switch ($tok.Value) {
                'join'   { $null = $ast.Joins.Add($this.ParseJoin()) }
                'top'    { $ast.Top    = $this.ParseTop() }
                'select' { $ast.Select = $this.ParseSelect() }
                'where'  { $ast.Where  = $this.ParseWhere() }
                'order'  { $this.ParseOrderBy($ast) }
                default  {
                    Write-Warning "Parser: unrecognized keyword '$($tok.Value)' at top level. Valid keywords are: join, select, where, order, top. This keyword was skipped."
                    $this.Consume()
                }
            }
        }

        return $ast
    }

    # -- Dotted identifier -----------------------------------------------------
    # Reassembles "a", "a.b", "a.b.c" from consecutive IDENTIFIER DOT IDENTIFIER tokens.
    # KEYWORD tokens are also accepted as identifier parts (e.g. field named "Type").

    [string] ParseDottedIdentifier() {
        $tok = $this.Consume()
        if ($null -eq $tok) {
            throw 'SQueryParser: expected identifier but got EOF'
        }
        if ($tok.Type -ne 'IDENTIFIER' -and $tok.Type -ne 'KEYWORD') {
            throw "SQueryParser: expected identifier but got '$($tok.Value)' (type=$($tok.Type))"
        }
        $result = $tok.Value

        while ($this.HasTokens() -and $this.IsType('DOT')) {
            $this.Consume()   # consume DOT
            $next = $this.Peek()
            if ($null -ne $next -and ($next.Type -eq 'IDENTIFIER' -or $next.Type -eq 'KEYWORD')) {
                $result += '.' + $this.Consume().Value
            } else {
                break
            }
        }

        return $result
    }

    # -- Join ------------------------------------------------------------------
    # join EntityPath [of type TypeFilter] Alias

    [object] ParseJoin() {
        $this.ExpectKeyword('join')

        $node = [JoinNode]::new()
        $node.EntityPath = $this.ParseDottedIdentifier()

        # Optional "of type TypeFilter"
        if ($this.IsKeyword('of')) {
            $this.ExpectKeyword('of')
            $this.ExpectKeyword('type')
            $node.TypeFilter = $this.ParseDottedIdentifier()
        }

        # Alias - the next IDENTIFIER or KEYWORD token (aliases are usually short like 'r', 'w')
        $aliasTok = $this.Consume()
        if ($null -eq $aliasTok) {
            throw "SQueryParser: expected alias after join entity '$($node.EntityPath)'"
        }
        $node.Alias = $aliasTok.Value

        return $node
    }

    # -- Top -------------------------------------------------------------------

    [int] ParseTop() {
        $this.ExpectKeyword('top')
        $numTok = $this.Consume()
        if ($null -eq $numTok -or $numTok.Type -ne 'NUMBER') {
            throw "SQueryParser: expected number after 'top'"
        }
        return [int]$numTok.Value
    }

    # -- Select ----------------------------------------------------------------
    # select field1, alias.field2, alias2.field3, ...

    [string[]] ParseSelect() {
        $this.ExpectKeyword('select')
        $fields = [System.Collections.ArrayList]::new()

        # First field
        if ($this.HasTokens() -and -not $this.IsClauseKeyword()) {
            $null = $fields.Add($this.ParseDottedIdentifier())
        }

        # Remaining fields after commas
        while ($this.HasTokens() -and $this.IsType('COMMA')) {
            $this.Consume()   # consume COMMA
            if (-not $this.HasTokens() -or $this.IsClauseKeyword()) { break }
            $null = $fields.Add($this.ParseDottedIdentifier())
        }

        return $fields.ToArray()
    }

    # -- Where -----------------------------------------------------------------

    [object] ParseWhere() {
        $this.ExpectKeyword('where')
        return $this.ParseOrExpr()
    }

    [object] ParseOrExpr() {
        $left = $this.ParseAndExpr()

        while ($this.HasTokens() -and $this.IsKeyword('or')) {
            $this.Consume()
            $right = $this.ParseAndExpr()
            $left  = [LogicalExpr]::new($left, 'OR', $right)
        }

        return $left
    }

    [object] ParseAndExpr() {
        $left = $this.ParseNotExpr()

        while ($this.HasTokens() -and $this.IsKeyword('and')) {
            $this.Consume()
            $right = $this.ParseNotExpr()
            $left  = [LogicalExpr]::new($left, 'AND', $right)
        }

        return $left
    }

    [object] ParseNotExpr() {
        if ($this.IsKeyword('not')) {
            $this.Consume()
            $child = $this.ParseNotExpr()
            return [NotExpr]::new($child)
        }
        return $this.ParsePrimary()
    }

    [object] ParsePrimary() {
        if ($this.IsType('LPAREN')) {
            $this.Consume()   # consume '('
            $expr = $this.ParseOrExpr()
            if ($this.IsType('RPAREN')) {
                $this.Consume()   # consume ')'
            } else {
                $got = if ($this.Peek()) { $this.Peek().Value } else { 'EOF' }
                Write-Warning "Parser: missing closing parenthesis ')' in WHERE clause. Got '$got' instead. The expression may be incorrectly grouped."
            }
            return $expr
        }

        return $this.ParseComparison()
    }

    [object] ParseComparison() {
        $field = $this.ParseDottedIdentifier()

        $opTok = $this.Consume()
        if ($null -eq $opTok -or $opTok.Type -ne 'OPERATOR') {
            $got = if ($opTok) { $opTok.Value } else { 'EOF' }
            throw "SQueryParser: expected operator after field '$field' but got '$got'"
        }

        $value = $this.ParseValue()
        return [CompareExpr]::new($field, $opTok.Value, $value)
    }

    [object] ParseValue() {
        $tok = $this.Peek()
        if ($null -eq $tok) {
            throw 'SQueryParser: expected value but got EOF'
        }

        $consumed = $this.Consume()
        switch ($consumed.Type) {
            'NUMBER'     { return [double]::Parse($consumed.Value, [System.Globalization.CultureInfo]::InvariantCulture) }
            'STRING'     { return $consumed.Value }
            'NULL'       { return $null }
            'BOOLEAN'    { return ($consumed.Value -eq 'true') }
            default      { return $consumed.Value }
        }
        # Unreachable, but satisfies static analysis
        return $consumed.Value
    }

    # -- Order By --------------------------------------------------------------
    # order by field [asc|desc] [, field [asc|desc]]*

    [void] ParseOrderBy([object]$ast) {
        $this.ExpectKeyword('order')
        $this.ExpectKeyword('by')

        # First sort item
        $this.AddSortNode($ast)

        # Additional sort items
        while ($this.HasTokens() -and $this.IsType('COMMA')) {
            $this.Consume()   # consume COMMA
            if (-not $this.HasTokens()) { break }
            $this.AddSortNode($ast)
        }
    }

    [void] AddSortNode([object]$ast) {
        $field     = $this.ParseDottedIdentifier()
        $direction = 'ASC'

        if ($this.IsKeyword('asc')) {
            $this.Consume()
            $direction = 'ASC'
        } elseif ($this.IsKeyword('desc')) {
            $this.Consume()
            $direction = 'DESC'
        }

        $node           = [SortNode]::new()
        $node.Field     = $field
        $node.Direction = $direction
        $null = $ast.OrderBy.Add($node)
    }
}
