# Lexer.ps1
# Tokenizes SQuery URL query strings into structured tokens

class SQueryToken {
    [string]$Type              # 'select', 'filter', 'sort', 'page', 'limit', 'offset'
    [string]$TopKey            # e.g., 'filter'
    [string]$NestedKey         # e.g., 'name' from 'filter[name]'
    [string]$Operator          # e.g., 'contains', 'eq', 'gt'
    [object]$Value             # The actual value (can be string, array, etc.)
    [int]$Position             # Position in query string for error reporting

    SQueryToken([string]$type, [string]$topKey, [string]$nestedKey,
                [string]$operator, [object]$value, [int]$position) {
        $this.Type = $type
        $this.TopKey = $topKey
        $this.NestedKey = $nestedKey
        $this.Operator = $operator
        $this.Value = $value
        $this.Position = $position
    }
}

class SQueryLexer {
    [string]$QueryString
    [SQueryToken[]]$Tokens

    SQueryLexer([string]$queryString) {
        $this.QueryString = $queryString
        $this.Tokens = @()
    }

    [SQueryToken[]] Tokenize() {
        if ([string]::IsNullOrWhiteSpace($this.QueryString)) {
            return @()
        }

        # Parse URL query string into key-value pairs
        $pairs = $this.QueryString.Split('&')
        $position = 0

        foreach ($pair in $pairs) {
            if ([string]::IsNullOrWhiteSpace($pair)) {
                $position += $pair.Length + 1
                continue
            }

            $parts = $pair.Split('=', 2)
            if ($parts.Count -ne 2) {
                Write-Warning "Skipping malformed pair at position $position`: $pair"
                $position += $pair.Length + 1
                continue
            }

            $key = [System.Web.HttpUtility]::UrlDecode($parts[0])
            $value = [System.Web.HttpUtility]::UrlDecode($parts[1])

            # Parse key for bracket notation: filter[name] or sort[date]
            if ($key -match '^(\w+)\[([^\]]+)\]$') {
                $topKey = $Matches[1]
                $nestedKey = $Matches[2]

                # Parse value for operator: contains:john
                $operator = 'eq'  # default operator
                $actualValue = $value

                if ($value -match '^(\w+):(.+)$') {
                    $operator = $Matches[1]
                    $actualValue = $Matches[2]
                }

                # Handle comma-separated values for IN operator
                if ($operator -in @('in', 'notin')) {
                    $actualValue = $actualValue.Split(',') | ForEach-Object { $_.Trim() }
                }

                $token = [SQueryToken]::new(
                    $topKey,      # Type: 'filter', 'sort'
                    $topKey,      # TopKey
                    $nestedKey,   # NestedKey: field name
                    $operator,    # Operator
                    $actualValue, # Value
                    $position     # Position
                )

                $this.Tokens += $token

            } elseif ($key -eq 'sort') {
                # Handle sort without brackets: sort=-CreatedDate,Name
                # Split by comma for multiple sort fields
                $sortFields = $value.Split(',')

                foreach ($sortField in $sortFields) {
                    $sortField = $sortField.Trim()

                    # Determine direction from prefix
                    $direction = 'asc'
                    $fieldName = $sortField

                    if ($sortField.StartsWith('-')) {
                        $direction = 'desc'
                        $fieldName = $sortField.Substring(1)
                    } elseif ($sortField.StartsWith('+')) {
                        $direction = 'asc'
                        $fieldName = $sortField.Substring(1)
                    }

                    $token = [SQueryToken]::new(
                        'sort',       # Type
                        'sort',       # TopKey
                        $fieldName,   # NestedKey: field name
                        $null,        # Operator (not used for sort)
                        $direction,   # Value: 'asc' or 'desc'
                        $position     # Position
                    )

                    $this.Tokens += $token
                }

            } elseif ($key -eq 'select') {
                # Handle select: select=Id,Name,Email
                $actualValue = $value.Split(',') | ForEach-Object { $_.Trim() }

                $token = [SQueryToken]::new(
                    'select',     # Type
                    'select',     # TopKey
                    $null,        # NestedKey
                    $null,        # Operator
                    $actualValue, # Value: array of field names
                    $position     # Position
                )

                $this.Tokens += $token

            } elseif ($key -in @('limit', 'offset', 'page')) {
                # Handle pagination parameters
                $type = $key.ToLower()

                $token = [SQueryToken]::new(
                    $type,        # Type
                    $key,         # TopKey
                    $null,        # NestedKey
                    $null,        # Operator
                    $value,       # Value
                    $position     # Position
                )

                $this.Tokens += $token

            } else {
                # Generic key-value pair
                $token = [SQueryToken]::new(
                    $key.ToLower(), # Type
                    $key,           # TopKey
                    $null,          # NestedKey
                    $null,          # Operator
                    $value,         # Value
                    $position       # Position
                )

                $this.Tokens += $token
            }

            $position += $pair.Length + 1
        }

        return $this.Tokens
    }

    [string] TokensToString() {
        $result = ""
        foreach ($token in $this.Tokens) {
            $result += "Token[$($token.Type)]"
            if ($token.NestedKey) {
                $result += "[$($token.NestedKey)]"
            }
            if ($token.Operator) {
                $result += " Op:$($token.Operator)"
            }
            $result += " = $($token.Value)"
            $result += "`n"
        }
        return $result
    }
}
