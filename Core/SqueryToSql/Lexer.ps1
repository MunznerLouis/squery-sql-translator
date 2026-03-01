# Lexer.ps1
# Tokenizes SQuery SQL-like string into a flat token stream
#
# SQuery grammar:
#   [join Entity alias]* [top N]? select fields [where condition]? [order by fields]?
#
# Input example (decoded):
#   "join Role r join WorkflowInstance w top 5 select Id, r.DisplayName where (OwnerType=2015) order by Id desc"

class SQueryToken {
    [string]$Type    # KEYWORD, IDENTIFIER, NUMBER, STRING, OPERATOR, LPAREN, RPAREN, COMMA, DOT, NULL
    [string]$Value   # Raw token value
    [int]$Position

    SQueryToken([string]$type, [string]$value, [int]$position) {
        $this.Type = $type
        $this.Value = $value
        $this.Position = $position
    }

    [string] ToString() {
        return "[$($this.Type):'$($this.Value)']"
    }
}

class SQueryLexer {
    [string]$DecodedInput
    [int]$Pos
    [System.Collections.ArrayList]$Tokens

    # Keywords (case-insensitive matching)
    hidden static [string[]]$Keywords = @(
        'join', 'of', 'type', 'top', 'select', 'where',
        'order', 'by', 'and', 'or', 'not', 'asc', 'desc'
    )

    # Accepts a pre-decoded SQuery string (caller handles URL-decoding)
    SQueryLexer([string]$sqQuery) {
        $this.DecodedInput = $sqQuery
        $this.Pos = 0
        $this.Tokens = [System.Collections.ArrayList]::new()
    }

    [array] Tokenize() {
        $this.Tokens.Clear()
        $sqInput = $this.DecodedInput
        $len = $sqInput.Length
        $this.Pos = 0

        while ($this.Pos -lt $len) {
            $ch = $sqInput[$this.Pos]

            # Skip whitespace
            if ([char]::IsWhiteSpace($ch)) {
                $this.Pos++
                continue
            }

            # Three-char operators: %=%
            if ($this.Pos + 2 -lt $len) {
                $three = $sqInput.Substring($this.Pos, 3)
                if ($three -eq '%=%') {
                    $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '%=%', $this.Pos))
                    $this.Pos += 3
                    continue
                }
            }

            # Two-char operators: !=  >=  <=  %=
            if ($this.Pos + 1 -lt $len) {
                $two = $sqInput.Substring($this.Pos, 2)
                if ($two -eq '!=' -or $two -eq '>=' -or $two -eq '<=' -or $two -eq '%=') {
                    $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', $two, $this.Pos))
                    $this.Pos += 2
                    continue
                }
            }

            # Single-char tokens
            if ($ch -eq '(') { $null = $this.Tokens.Add([SQueryToken]::new('LPAREN',   '(', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq ')') { $null = $this.Tokens.Add([SQueryToken]::new('RPAREN',   ')', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq ',') { $null = $this.Tokens.Add([SQueryToken]::new('COMMA',    ',', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq '.') { $null = $this.Tokens.Add([SQueryToken]::new('DOT',      '.', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq '=') { $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '=', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq '>') { $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '>', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq '<') { $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '<', $this.Pos)); $this.Pos++; continue }
            if ($ch -eq '!') { $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '!', $this.Pos)); $this.Pos++; continue }
            # Standalone % means LIKE/contains
            if ($ch -eq '%') { $null = $this.Tokens.Add([SQueryToken]::new('OPERATOR', '%=', $this.Pos)); $this.Pos++; continue }

            # Negative number: - followed by a digit
            if ($ch -eq '-' -and $this.Pos + 1 -lt $len -and [char]::IsDigit($sqInput[$this.Pos + 1])) {
                $start = $this.Pos
                $this.Pos++   # skip '-'
                while ($this.Pos -lt $len -and ([char]::IsDigit($sqInput[$this.Pos]) -or $sqInput[$this.Pos] -eq '.')) {
                    $this.Pos++
                }
                $num = $sqInput.Substring($start, $this.Pos - $start)
                $null = $this.Tokens.Add([SQueryToken]::new('NUMBER', $num, $start))
                continue
            }

            # Single-quoted string
            if ($ch -eq "'") {
                $start = $this.Pos
                $this.Pos++
                $sb = [System.Text.StringBuilder]::new()
                while ($this.Pos -lt $len -and $sqInput[$this.Pos] -ne "'") {
                    $null = $sb.Append($sqInput[$this.Pos])
                    $this.Pos++
                }
                $this.Pos++ # skip closing quote
                $null = $this.Tokens.Add([SQueryToken]::new('STRING', $sb.ToString(), $start))
                continue
            }

            # Double-quoted string
            if ($ch -eq '"') {
                $start = $this.Pos
                $this.Pos++
                $sb = [System.Text.StringBuilder]::new()
                while ($this.Pos -lt $len -and $sqInput[$this.Pos] -ne '"') {
                    $null = $sb.Append($sqInput[$this.Pos])
                    $this.Pos++
                }
                $this.Pos++ # skip closing quote
                $null = $this.Tokens.Add([SQueryToken]::new('STRING', $sb.ToString(), $start))
                continue
            }

            # Numbers (digits only; negative numbers handled by operator '-' + number)
            if ([char]::IsDigit($ch)) {
                $start = $this.Pos
                while ($this.Pos -lt $len -and ([char]::IsDigit($sqInput[$this.Pos]) -or $sqInput[$this.Pos] -eq '.')) {
                    $this.Pos++
                }
                $num = $sqInput.Substring($start, $this.Pos - $start)
                $null = $this.Tokens.Add([SQueryToken]::new('NUMBER', $num, $start))
                continue
            }

            # Identifiers and keywords (letters, digits, underscore, colon for typed joins like "Workflow_Directory_FR_User:Directory_FR_User")
            if ([char]::IsLetter($ch) -or $ch -eq '_') {
                $start = $this.Pos
                while ($this.Pos -lt $len) {
                    $c = $sqInput[$this.Pos]
                    if ([char]::IsLetterOrDigit($c) -or $c -eq '_' -or $c -eq ':') {
                        $this.Pos++
                    } else {
                        break
                    }
                }
                $word = $sqInput.Substring($start, $this.Pos - $start)
                $wordLower = $word.ToLower()

                if ($wordLower -eq 'null') {
                    $null = $this.Tokens.Add([SQueryToken]::new('NULL', 'null', $start))
                } elseif ($wordLower -eq 'true' -or $wordLower -eq 'false') {
                    $null = $this.Tokens.Add([SQueryToken]::new('BOOLEAN', $wordLower, $start))
                } elseif ($wordLower -in [SQueryLexer]::Keywords) {
                    $null = $this.Tokens.Add([SQueryToken]::new('KEYWORD', $wordLower, $start))
                } else {
                    $null = $this.Tokens.Add([SQueryToken]::new('IDENTIFIER', $word, $start))
                }
                continue
            }

            # Unknown - skip with warning
            Write-Warning "Lexer: unexpected character '$ch' at position $($this.Pos). This character is not part of SQuery syntax and was skipped."
            $this.Pos++
        }

        return $this.Tokens.ToArray()
    }
}
