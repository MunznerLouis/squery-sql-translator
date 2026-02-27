# SQuery-SQL-Translator - Complete Project Specification

## What This Project Does

This is a **PowerShell module** that translates **SQuery URLs** (a proprietary SQL-like query language embedded in REST API URLs, used by **Netwrix Identity Manager** / Brainware IGA) into **parameterized SQL Server queries**.

**Input**: A full HTTP URL containing a `squery=` query parameter
**Output**: A SQL Server SELECT query with inlined values

### Example

**Input URL:**
```
http://localhost:5000/api/ProvisioningPolicy/AssignedSingleRole?api-version=1.0
  &squery=join+Role+r+top+5+select+Id,+StartDate,+r.DisplayName+where+(OwnerType%3D2015)+order+by+Id+desc
  &QueryRootEntityType=AssignedSingleRole
```

**Output SQL:**
```sql
SELECT TOP 5 asr.Id, asr.StartDate, r.DisplayName_L1
FROM [dbo].[UP_AssignedSingleRoles] asr
LEFT JOIN [dbo].[UP_SingleRoles] r ON asr.Role_Id = r.Id
WHERE asr.OwnerType = 2015
ORDER BY asr.Id DESC
```

---

## The SQuery Language

SQuery is a SQL-like mini-language embedded in a single URL parameter. It supports:

### Grammar
```
[join EntityPath [of type TypeFilter] alias]*
[top N]?
select field1, alias.field2, ...
[where (conditions)]?
[order by field asc|desc, ...]*
```

### URL Structure
```
http://host/api/{module}/{EntityType}/{optionalId}?api-version=X
  &squery={url-encoded-squery}
  &QueryRootEntityType={entityName}
  &Path={path}
```

- The root entity comes from `QueryRootEntityType` param, or falls back to the last URL path segment.
- The `squery=` value is URL-encoded (spaces become `+`, operators like `=` become `%3D`).

### Join Syntax
```
join Role r                              -- simple nav prop join
join r.Policy rp                         -- chained join (nav prop on alias r)
join Owner of type Directory_FR_User o   -- polymorphic typed join
join Workflow_User:Directory_FR_User u   -- colon type-filter syntax
```

### WHERE Operators
| SQuery | SQL | Notes |
|--------|-----|-------|
| `=` | `=` | Equality |
| `!=` | `!=` | Not equal |
| `>`, `>=`, `<`, `<=` | Same | Comparisons |
| `%=` or `%=%` | `LIKE '%val%'` | Contains |
| `= null` | `IS NULL` | Null check |
| `!= null` | `IS NOT NULL` | Not null check |

- AND, OR, NOT, parentheses for grouping
- Values: numbers (int/float), strings (single or double quoted), booleans (`true`/`false`), `null`

---

## PowerShell Compatibility Notes

- Targets **PowerShell 5.1** (Windows PowerShell) and PowerShell Core
- All `.ps1` files must be saved with **UTF-8 BOM** encoding (PS 5.1 reads non-BOM files as Windows-1252, causing parse errors with Unicode characters)
- Custom class types cannot be used as method parameter types in PS 5.1 -- use `[object]` instead
- `$input` is a reserved automatic variable -- renamed to `$sqInput` in class methods
- `[ordered]@{}` creates `OrderedDictionary` -- use `.Contains()` not `.ContainsKey()`

