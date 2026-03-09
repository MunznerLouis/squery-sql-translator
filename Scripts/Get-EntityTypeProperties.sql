-- Get-EntityTypeProperties.sql
-- Discovery query for Resource EntityType column mappings and navigation properties.
-- Run this in SSMS against your Netwrix Identity Manager database,
-- then export the result as a semicolon-delimited CSV to import with:
--   Update-SQueryEntityTypes -CsvPath <path>
--
-- Columns: EntityType_Id;Identifier;Property;Property_Id;TargetColumnIndex;Property1;Property2;TargetEntityType
-- TargetColumnIndex: 0-127 = scalar C-columns, 128-152 = mono-valued nav I-columns, -1 = multi-valued nav
-- Property1/Property2: from UM_EntityAssociations (bidirectional link between two properties)

SELECT DISTINCT
    ep.EntityType_Id,
    et.Identifier,
    ep.Identifier AS Property,
    ep.Id AS Property_Id,
    ep.TargetColumnIndex,
    ea1.Property1_Id AS Property1,
    ea1.Property2_Id AS Property2,
    ep.TargetEntityType
FROM [dbo].[UM_EntityProperties] ep
LEFT JOIN UM_EntityTypes et ON et.Id = ep.EntityType_Id
LEFT JOIN UM_EntityAssociations ea1 ON ea1.Property1_Id = ep.Id
WHERE et.ValidTo > CURRENT_TIMESTAMP
ORDER BY ep.EntityType_Id, ep.Identifier
