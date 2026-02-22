-- =============================================================================
-- Export complet du schéma de la BDD (sans données)
-- Tables + Colonnes + Types + Foreign Keys
-- =============================================================================

-- 1. Toutes les colonnes de toutes les tables avec leurs types
SELECT 
    t.name                          AS TableName,
    c.name                          AS ColumnName,
    ty.name                         AS DataType,
    CASE 
        WHEN ty.name IN ('nvarchar','nchar') THEN c.max_length / 2
        WHEN ty.name IN ('varchar','char','varbinary') THEN c.max_length
        ELSE NULL
    END                             AS MaxLength,
    c.is_nullable                   AS Nullable,
    c.is_identity                   AS IsIdentity,
    c.column_id                     AS OrdinalPosition
FROM sys.tables  t
JOIN sys.columns c  ON t.object_id = c.object_id
JOIN sys.types   ty ON c.user_type_id = ty.user_type_id
WHERE t.is_ms_shipped = 0
ORDER BY t.name, c.column_id


-- 2. Toutes les relations Foreign Key
SELECT
    tp.name                         AS ParentTable,
    cp.name                         AS ParentColumn,
    tr.name                         AS ReferencedTable,
    cr.name                         AS ReferencedColumn,
    fk.name                         AS FK_Name,
    fk.delete_referential_action_desc AS OnDelete,
    fk.update_referential_action_desc AS OnUpdate
FROM sys.foreign_keys            fk
JOIN sys.foreign_key_columns     fkc ON fk.object_id = fkc.constraint_object_id
JOIN sys.tables                  tp  ON fkc.parent_object_id = tp.object_id
JOIN sys.columns                 cp  ON fkc.parent_object_id = cp.object_id 
                                    AND fkc.parent_column_id = cp.column_id
JOIN sys.tables                  tr  ON fkc.referenced_object_id = tr.object_id
JOIN sys.columns                 cr  ON fkc.referenced_object_id = cr.object_id 
                                    AND fkc.referenced_column_id = cr.column_id
ORDER BY tp.name, cp.name


-- 3. Primary Keys (utile pour savoir quelle colonne est PK sur chaque table)
SELECT
    t.name                          AS TableName,
    c.name                          AS ColumnName,
    i.name                          AS PK_Name
FROM sys.indexes         i
JOIN sys.index_columns   ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.tables          t  ON i.object_id = t.object_id
JOIN sys.columns         c  ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.is_primary_key = 1
ORDER BY t.name, ic.key_ordinal
