# Module manifest for SQuery-SQL-Translator

@{
    # Script module or binary module file associated with this manifest
    RootModule = 'SQuery-SQL-Translator.psm1'

    # Version number of this module
    ModuleVersion = '1.3.0'

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
    Description = 'Translates SQuery (SQL-like URL query language used by Netwrix Identity Manager) to SQL. Parses join/select/where/order-by clauses, resolves JOIN navigation properties via JSON configuration, and inlines WHERE values directly into the output query string.'

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
        'Get-SQueryConfigPath',
        'Initialize-Workspace',
        'Update-SQueryEntityTypes'
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
            ProjectUri = ''

            # A URL to an icon representing this module
            IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
## v1.3.0

- CSV import support for Resource EntityType column mappings (semicolon-delimited).
- SQL Server auto-connect mode: discovers EntityTypes directly from the IM database.
- Real entityTypeId values: uses WHERE Type=N instead of INNER JOIN UM_EntityTypes (faster).
- Interactive SQuery-To-SQL.ps1 launcher script with menu-driven workflow.
- 64 Resource EntityTypes included in Default config out of the box.
- Initialize-Workspace wizard with AUTO (SQL Server) and MANUAL (CSV) modes.
- Discovery SQL query saved in Scripts/Get-EntityTypeProperties.sql for reference.

## v1.2.0

- WHERE values are now inlined as SQL literals in the output query (numbers unquoted,
  strings single-quoted, booleans as 1/0, null as NULL).
- join-patterns.json compact form: localKey defaults to {NavPropName}_Id, foreignKey
  defaults to Id; only non-standard keys need to be specified explicitly.

## v1.1.0

- Resource EntityType support: Directory_FR_User, Workday_Person_FR, SAP_Person and
  other UR_Resources subtypes resolve to [dbo].[UR_Resources] with C{index} columns.
- EntityType filter injected automatically (INNER JOIN UM_EntityTypes or WHERE Type=N).
- resourceSubType double-JOIN for Resource-to-Resource subtype navigation.
- entity-specific aliases in database-mapping.json (asr, rcr, rt, wi, etc.).

## v1.0.0

SQuery grammar supported:
  [join Entity alias]* [join Entity of type SubType alias]* [join a.NavProp alias]*
  [top N]? select field1, alias.field2, ... [where expr]? [order by field asc|desc, ...]*

WHERE operators: = != > >= < <= %=/%=% (LIKE) = null (!= null)
AND / OR / NOT / parentheses supported.

Config-driven JOIN resolution via join-patterns.json.
'@
        }
    }

    # HelpInfo URI of this module
    HelpInfoURI = ''
}
