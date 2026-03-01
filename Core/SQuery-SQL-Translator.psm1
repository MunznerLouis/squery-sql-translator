# SQuery-SQL-Translator PowerShell Module
# Bidirectional translator between SQuery and SQL

# Get module directory
$ModuleRoot = $PSScriptRoot

# Load System.Web assembly for URL decoding
Add-Type -AssemblyName System.Web

# Load shared components
. "$ModuleRoot\Shared\ConfigLoader.ps1"
. "$ModuleRoot\Shared\WorkspaceInitializer.ps1"

# Load SQuery to SQL components
. "$ModuleRoot\SqueryToSql\Lexer.ps1"
. "$ModuleRoot\SqueryToSql\Parser.ps1"
. "$ModuleRoot\SqueryToSql\Validator.ps1"
. "$ModuleRoot\SqueryToSql\Transformer.ps1"

# Define default config path
$script:DefaultConfigPath = Join-Path $ModuleRoot "..\Configs\Default"

<#
.SYNOPSIS
Converts an SQuery URL to a parameterized SQL query.

.DESCRIPTION
Parses an SQuery-formatted URL query string and converts it to a SQL query based on JSON
configuration files. WHERE values are inlined as SQL literals in the output query string.
Returns a hashtable with the final SQL query and the original parameter values.

.PARAMETER Url
The complete URL containing SQuery syntax in the query string.

.PARAMETER QueryString
The query string portion only (without URL). Use this with -RootEntity.

.PARAMETER RootEntity
The root entity/table name (e.g., 'User', 'Order'). Required when using -QueryString.

.PARAMETER ConfigPath
Path to the directory containing configuration JSON files. If not specified, uses default configuration.

.PARAMETER ValidateOnly
If specified, only validates the query without generating SQL. Returns validation results.

.EXAMPLE
$url = "http://localhost:5000/api/ProvisioningPolicy/AssignedSingleRole?api-version=1.0&squery=join+Role+r+top+5+select+Id,+StartDate,+r.DisplayName+where+(OwnerType%3D2015)+order+by+Id+desc&QueryRootEntityType=AssignedSingleRole"
$result = Convert-SQueryToSql -Url $url
Write-Host $result.Query
# Output: SELECT TOP 5 asr.Id, asr.StartDate, r.DisplayName_L1
#         FROM [dbo].[UP_AssignedSingleRoles] asr
#         LEFT JOIN [dbo].[UP_SingleRoles] r ON asr.Role_Id = r.Id
#         WHERE asr.OwnerType = 2015
#         ORDER BY asr.Id DESC

.OUTPUTS
Hashtable with keys:
- Query: The SQL query string with values inlined as literals
- Parameters: Hashtable of the original parameter names and values
- Warnings: Array of warning messages (if any)
#>
function Convert-SQueryToSql {
    [CmdletBinding(DefaultParameterSetName='FromUrl')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true, ParameterSetName='FromUrl', Position=0, ValueFromPipeline=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true, ParameterSetName='FromQueryString')]
        [string]$QueryString,

        [Parameter(Mandatory=$true, ParameterSetName='FromQueryString')]
        [string]$RootEntity,

        [Parameter(Mandatory=$false)]
        [string]$ConfigPath = $script:DefaultConfigPath,

        [Parameter(Mandatory=$false)]
        [switch]$ValidateOnly
    )

    begin {
        Write-Verbose "Loading configuration from: $ConfigPath"
        try {
            $config = [ConfigLoader]::new($ConfigPath)
        } catch {
            throw "Failed to load configuration: $($_.Exception.Message)"
        }
    }

    process {
        try {
            # Extract squery= and QueryRootEntityType= parameters from URL
            if ($PSCmdlet.ParameterSetName -eq 'FromUrl') {
                try {
                    $uri = [System.Uri]$Url
                    $rawQueryString = $uri.Query.TrimStart('?')

                    # Parse individual query parameters
                    $parsedParams = [System.Web.HttpUtility]::ParseQueryString($rawQueryString)

                    # Prefer QueryRootEntityType= param; fall back to last URL path segment
                    if (-not [string]::IsNullOrWhiteSpace($parsedParams['QueryRootEntityType'])) {
                        $RootEntity = $parsedParams['QueryRootEntityType']
                        Write-Verbose "Root entity from QueryRootEntityType: $RootEntity"
                    } else {
                        $pathSegments = $uri.AbsolutePath.Trim('/').Split('/')
                        if ($pathSegments.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($pathSegments[-1])) {
                            $RootEntity = $pathSegments[-1]
                            Write-Verbose "Root entity inferred from URL path: $RootEntity"
                        } else {
                            throw "Cannot determine root entity. URL must contain QueryRootEntityType= param or -RootEntity must be supplied."
                        }
                    }

                    # Extract squery= value (ParseQueryString already URL-decodes it)
                    $sqValue = $parsedParams['squery']
                    if ($null -ne $sqValue) {
                        $QueryString = $sqValue
                        Write-Verbose "Extracted squery parameter"
                    } else {
                        throw "No squery= parameter found in URL. Expected format: ...?squery=join+...+select+...&QueryRootEntityType=EntityName"
                    }

                } catch [System.UriFormatException] {
                    throw "Invalid URL format: $Url"
                }
            }

            if ([string]::IsNullOrWhiteSpace($QueryString)) {
                Write-Warning "SQuery string is empty (no squery= parameter or blank value). Generating a basic 'SELECT *' for entity '$RootEntity'."
            }

            Write-Verbose "SQuery: $QueryString"
            Write-Verbose "Root Entity: $RootEntity"

            # LEXER: Tokenize the SQuery string
            Write-Verbose "Tokenizing SQuery string..."
            $lexer = [SQueryLexer]::new($QueryString)
            $tokens = $lexer.Tokenize()
            Write-Verbose "Generated $($tokens.Count) tokens"

            # PARSER: Build AST
            Write-Verbose "Parsing tokens into AST..."
            $parser = [SQueryParser]::new($tokens, $RootEntity)
            $ast = $parser.Parse()
            Write-Verbose "AST: $($ast.ToString())"

            # VALIDATOR: Validate against configuration
            Write-Verbose "Validating query..."
            $validator = [SQueryValidator]::new($ast, $config)
            $isValid = $validator.Validate()

            if (-not $isValid) {
                $errors = $validator.GetErrors()
                $errorMessage = "Query validation failed:`n" + ($errors -join "`n")
                throw $errorMessage
            }

            $warnings = $validator.GetWarnings()
            if ($warnings.Count -gt 0) {
                foreach ($warning in $warnings) {
                    Write-Warning $warning
                }
            }

            if ($ValidateOnly) {
                return @{
                    Valid = $true
                    Warnings = $warnings
                    Message = "Query is valid"
                }
            }

            # TRANSFORMER: Convert to SQL Builder
            Write-Verbose "Transforming to SQL..."
            $transformer = [SQueryTransformer]::new($ast, $config)
            $builder = $transformer.Transform()

            # BUILD: Generate final SQL
            Write-Verbose "Building SQL query..."
            $result = $builder.Build()

            # Add warnings to result
            if ($warnings.Count -gt 0) {
                $result['Warnings'] = $warnings
            }

            Write-Verbose "SQL generation complete"
            Write-Verbose "Query: $($result.Query)"
            Write-Verbose "Parameters: $($result.Parameters.Count)"

            return $result

        } catch {
            $errorDetails = @{
                Message = $_.Exception.Message
                Category = $_.CategoryInfo.Category
                Line = $_.InvocationInfo.ScriptLineNumber
            }

            Write-Error "Failed to convert SQuery to SQL: $($errorDetails.Message)"
            throw
        }
    }
}

<#
.SYNOPSIS
Tests the SQuery configuration files for validity.

.DESCRIPTION
Validates all configuration JSON files in the specified directory and reports any errors or warnings.
Checks for proper schema structure, cross-references between files, and required properties.

.PARAMETER ConfigPath
Path to the directory containing configuration JSON files (database-mapping.json, column-rules.json, operator.json).

.EXAMPLE
Test-SQueryConfiguration -ConfigPath "./Configs/Default"

.EXAMPLE
if (Test-SQueryConfiguration -ConfigPath "./MyProject/configs") {
    Write-Host "Configuration is valid! Ready to use."
}

.OUTPUTS
Boolean indicating whether configuration is valid
#>
function Test-SQueryConfiguration {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$ConfigPath
    )

    try {
        Write-Host "Testing configuration at: $ConfigPath" -ForegroundColor Cyan

        # Check if directory exists
        if (-not (Test-Path $ConfigPath -PathType Container)) {
            Write-Host "Configuration directory not found: $ConfigPath" -ForegroundColor Red
            return $false
        }

        # Try to load configuration
        $config = [ConfigLoader]::new($ConfigPath)

        Write-Host "Configuration loaded successfully!" -ForegroundColor Green

        # Report statistics
        $entityCount = $config.DatabaseMapping.tables.Keys.Count
        $operatorCount = $config.Operators.operators.Keys.Count

        Write-Host "`nConfiguration Statistics:" -ForegroundColor Cyan
        Write-Host "  Entities defined: $entityCount"
        Write-Host "  Operators defined: $operatorCount"

        # List entities
        Write-Host "`nAvailable Entities:" -ForegroundColor Cyan
        foreach ($entity in $config.DatabaseMapping.tables.Keys) {
            $tableInfo = $config.DatabaseMapping.tables[$entity]
            $fieldCount = $tableInfo.allowedFields.Count
            Write-Host "  - $entity ($($tableInfo.tableName)) - $fieldCount fields"
        }

        # List operators
        Write-Host "`nAvailable Operators:" -ForegroundColor Cyan
        $opsByType = $config.Operators.operators.GetEnumerator() | Group-Object { $_.Value.conditionType }
        foreach ($group in $opsByType) {
            $ops = ($group.Group | ForEach-Object { $_.Key }) -join ', '
            Write-Host "  [$($group.Name)]: $ops"
        }

        return $true

    } catch {
        Write-Host '' -ForegroundColor Red
        Write-Host 'Configuration validation failed!' -ForegroundColor Red
        Write-Host 'Error: ' $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

<#
.SYNOPSIS
Gets the current default configuration path.

.DESCRIPTION
Returns the path to the default configuration directory being used by the module.
Useful for troubleshooting or when you want to know which configuration is active.

.EXAMPLE
$configPath = Get-SQueryConfigPath
Write-Host 'Using configuration from: ' $configPath

.OUTPUTS
String path to the default configuration directory
#>
function Get-SQueryConfigPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:DefaultConfigPath
}

# Export module members (defined in manifest)
Export-ModuleMember -Function @(
    'Convert-SQueryToSql',
    'Test-SQueryConfiguration',
    'Get-SQueryConfigPath',
    'Initialize-Workspace',
    'Update-SQueryEntityTypes'
)
