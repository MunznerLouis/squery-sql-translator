# How a SQuery Becomes SQL

## 1. URL Parsing

A URL comes in like:

```
/api/module/AssignedSingleRole?squery=join Role r top 5 select Id, r.DisplayName where (OwnerType=2015) order by Id desc&QueryRootEntityType=AssignedSingleRole
```

The module extracts three things: the **root entity** (`AssignedSingleRole`), an optional **entity ID** from the path (e.g. `/21177`), and the **squery string** which gets URL-decoded.

## 2. Lexing

The Lexer walks through the decoded squery string character by character and breaks it into tokens. `join Role r top 5 select Id` becomes:

```
[KEYWORD:'join'] [IDENTIFIER:'Role'] [IDENTIFIER:'r'] [KEYWORD:'top'] [NUMBER:'5'] [KEYWORD:'select'] [IDENTIFIER:'Id']
```

It recognizes keywords (`join`, `select`, `where`, `order`, `by`, `and`, `or`, `not`, etc.), identifiers, numbers, strings (single/double quoted), operators (`=`, `!=`, `>=`, `%=`, etc.), parens, commas, and dots. If a string is never closed or a character is unrecognized, it throws immediately.

## 3. Parsing

The Parser consumes the token stream and builds an Abstract Syntax Tree (AST). It processes tokens left to right, dispatching on the top-level keyword:

- **join** creates a JoinNode with an entity path (`Role`, or `r.Policy` for chained joins), an optional type filter (`of type <EntityType>`), and an alias (`r`)
- **top** stores the limit number
- **select** collects a comma-separated list of dotted field references (`Id`, `r.DisplayName`)
- **where** recursively parses a boolean expression tree respecting AND/OR precedence, NOT, parentheses, and comparisons (`field op value`). Missing closing parens throw an error.
- **order by** collects field + direction (ASC/DESC) pairs

The result is a single `SQueryAST` object holding: root entity, optional entity ID, joins list, top value, select fields, where tree, and order-by list.

## 4. Validation

The Validator checks the AST against the loaded configuration before any SQL is generated:

- Root entity must exist in `correlation.json > entityToTable` (or be a known Resource EntityType)
- TOP value can't be negative
- Every JOIN alias must be unique and not collide with the root alias
- Every JOIN's navigation property must resolve through the config (warns if not, so the JOIN gets skipped gracefully)
- Every alias used in SELECT/WHERE/ORDER BY must reference a declared JOIN
- Fields are checked against the entity's known properties from `squery-schema.json`
- WHERE tree depth is capped at 10 to prevent abuse

Errors block translation. Warnings let it proceed but inform the user something may be off.

## 5. Transformation

The Transformer walks the AST and builds SQL piece by piece into a `SqlQueryBuilder`:

### FROM

The root entity is looked up in config. `AssignedSingleRole` maps to `[dbo].[UP_AssignedSingleRoles]` with auto-generated alias `asr`. If the root entity is a Resource EntityType, it maps to `[dbo].[UR_Resources]` instead, and a `WHERE Type = N` filter is queued using the entity's numeric type ID.

### JOINs

Each JoinNode is resolved through a 4-tier navigation property lookup:

1. **Manual overrides** in `correlation.json` — hardcoded mappings for entities where the FK pattern is non-standard (e.g. `Policy.SimulationPolicy` uses `PolicySimulation_Id`, not `SimulationPolicy_Id`)
2. **SQL schema auto-deduction** — looks for a `{navPropName}_Id` foreign key in `sql-schema.json` and follows it to the referenced table
3. **Resource EntityType nav props** from `resource-nav-props.json` — for I-column joins (mono-valued, like `PresenceState` via `dfru.I40 = ps.Id`) and reverse joins (multi-valued, like `Records` on a User)
4. **Resource generic defaults** — first from `resource-nav-props.json` auto-generated associations (like `AssignedSingleRoles`), then falling back to `correlation.json` for structural FK columns like `Owner`

Once a nav prop resolves, the Transformer emits a `LEFT JOIN` (or `INNER JOIN` if specified) with the ON clause built from `localKey` and `foreignKey`. If the target is `UR_Resources`, a `Type = N` filter can be added to the ON clause, and a `ValidTo > CURRENT_TIMESTAMP` filter is queued for WHERE.

For "of type" joins (polymorphic Resource subtypes like `join Owner of type EntityType`), it emits a double JOIN: first an `UM_EntityTypes` lookup to resolve the type name to an ID, then the actual `UR_Resources` join filtered by that type.

### SELECT

Each field goes through column renaming:

1. Entity-specific overrides (`RoleId` → `ResourceType_Id` for AssignedResourceType)
2. Resource EntityType column map (`DisplayName` → `CC` for `EntityType`)
3. Global renames (`DisplayName` → `DisplayName_L1`, `FullName` → `FullName_L1`)
4. FK auto-rename (`FooId` → `Foo_Id`)

Fields are prefixed with their alias: `r.DisplayName` becomes `r.DisplayName_L1`.

### WHERE

The expression tree is walked recursively. Each comparison becomes `alias.dbColumn op @pN` with the value stored as a named parameter. `NULL` becomes `IS NULL` / `IS NOT NULL`. LIKE operators wrap the value in `%`. Logical nodes become `(left AND right)` or `(left OR right)`. System filters (entity ID, `Type=N`, `ValidTo`) are prepended before the user's WHERE clause.

### ORDER BY

Same field resolution as SELECT, with ASC/DESC appended.

## 6. Assembly

The `SqlQueryBuilder` assembles all parts in order: `SELECT [TOP N] fields` > `FROM table alias` > JOINs > `WHERE` > `ORDER BY`. Parameter placeholders (`@p1`, `@p2`) are then inlined as SQL literals (strings get single-quote escaped, numbers stay raw, booleans become 0/1, nulls become NULL).

The final output is a single SQL string ready to execute against the Identity Manager database.

## Visual Overview

See [pipeline.svg](pipeline.svg) for a visual diagram of the full pipeline.
