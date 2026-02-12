-- Get-EntityTypeProperties.sql
-- Discovery query for Resource EntityType column mappings.
-- Run this in SSMS against your Netwrix Identity Manager database,
-- then export the result as a semicolon-delimited CSV to import with:
--   Update-SQueryEntityTypes -CsvPath <path>

SELECT DISTINCT ep.EntityType_Id, et.Identifier, ep.Identifier AS Property, ep.TargetColumnIndex
  FROM [dbo].[UM_EntityProperties] ep
  LEFT JOIN UM_EntityTypes et ON et.Id = ep.EntityType_Id
  WHERE NOT ep.TargetColumnIndex = -1 AND et.ValidTo > CURRENT_TIMESTAMP
  ORDER BY ep.EntityType_Id, ep.TargetColumnIndex
