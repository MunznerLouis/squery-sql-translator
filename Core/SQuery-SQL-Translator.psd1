# Module manifest for SQuery-SQL-Translator

@{
    # Script module or binary module file associated with this manifest
    RootModule = 'SQuery-SQL-Translator.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Core', 'Desktop')

    # ID used to uniquely identify this module
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'

    # Author of this module
    Author = 'Louis Münzner'

    # Company or vendor of this module
    CompanyName = 'Ariovis'

    # Copyright statement for this module
    Copyright = '(c) 2026. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Translates SQuery (SQL-like URL query language used by Brainware/Netwrix Identity Manager) to parameterized SQL. Parses join/select/where/order-by clauses and resolves JOIN navigation properties via JSON configuration.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'Convert-SQueryToSql',
        'Test-SQueryConfiguration',
        'Get-SQueryConfigPath'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            # Tags applied to this module
            Tags = @('SQL', 'Query', 'Translation', 'SQuery', 'REST', 'API', 'Converter', 'Parser')

            # A URL to the license for this module
            LicenseUri = ''

            # A URL to the main website for this project
            ProjectUri = 'https://github.com/you/SQuery-SQL-Translator'

            # A URL to an icon representing this module
            IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
## v1.0.0

SQuery grammar supported:
  [join Entity alias]* [join Entity of type SubType alias]* [join a.NavProp alias]*
  [top N]? select field1, alias.field2, ... [where expr]? [order by field asc|desc, ...]*

WHERE operators: = != > >= < <= %=/%=% (LIKE) = null (!= null)
AND / OR / NOT / parentheses supported.

Config-driven JOIN resolution via join-patterns.json.
All WHERE values fully parameterized (@p1, @p2, ...).
'@
        }
    }

    # HelpInfo URI of this module
    HelpInfoURI = ''
}
