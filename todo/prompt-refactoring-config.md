# Tâche : Refactoring du système de configuration — auto-génération depuis le schéma DB

## Contexte

Le projet `squery-sql-translator` est un traducteur SQuery → SQL en PowerShell.
Il utilise actuellement 5 fichiers JSON de config maintenus à la main dans `Configs/Default/` :
- `database-mapping.json` — tables, alias, allowedFields (tout est à `["*"]` aujourd'hui)
- `join-patterns.json` — navigation properties pour les JOINs (localKey, foreignKey, targetTable, targetEntity)
- `column-rules.json` — renommages de colonnes (globalRenames + overrides par entity)
- `resource-columns.json` — mapping spécial pour les entités Resource (EntityType dynamiques)
- `operator.json` — mapping opérateurs SQuery → SQL (ne change pas, on n'y touche pas)

Le problème : ces fichiers sont incomplets, redondants entre eux, et maintenus à la main.

Je te fournis en contexte un fichier SQL (`export-db-schema.sql`) qui contient 3 queries à exécuter sur la BDD pour obtenir :
1. Toutes les tables + colonnes + types + nullable + identity
2. Toutes les Foreign Keys (parent → referenced)
3. Toutes les Primary Keys

Le résultat de ces queries sera exporté en CSV ou JSON (je te le fournirai).

## Ce qu'il faut faire

### 1. Créer un script `Scripts/Import-DbSchema.ps1`

Ce script prend en entrée les résultats des 3 queries (CSV ou JSON, à toi de choisir le format le plus pratique) et génère un fichier `Configs/Default/db-schema.json` structuré comme suit :

```json
{
  "version": "1.0",
  "tables": {
    "UP_AssignedSingleRoles": {
      "columns": {
        "Id": { "dataType": "bigint", "nullable": false, "isIdentity": true },
        "Role_Id": { "dataType": "bigint", "nullable": true, "isIdentity": false },
        "StartDate": { "dataType": "datetime", "nullable": true, "isIdentity": false }
      },
      "primaryKey": ["Id"],
      "foreignKeys": {
        "Role_Id": { "referencedTable": "UP_SingleRoles", "referencedColumn": "Id" }
      }
    }
  }
}
```

Ce fichier est auto-généré et ne doit JAMAIS être édité à la main.

### 2. Créer un fichier `Configs/Default/overrides.json`

C'est le fichier de surcharges manuelles. Il contient tout ce que l'export SQL ne peut pas deviner :

```json
{
  "version": "1.0",
  "description": "Surcharges manuelles appliquées par-dessus db-schema.json",

  "entityAliases": {
    "AssignedSingleRole": { "tableName": "UP_AssignedSingleRoles", "alias": "asr" },
    "SingleRole": { "tableName": "UP_SingleRoles", "alias": "sr" }
  },

  "globalColumnRenames": {
    "DisplayName": "DisplayName_L1",
    "FullName": "FullName_L1",
    "InternalDisplayName": "InternalDisplayName_L1"
  },

  "entityColumnOverrides": {
  },

  "resourceEntityTypes": {
  }
}
```

Pour le contenu initial de `entityAliases`, reprends les valeurs existantes dans `database-mapping.json` actuel.
Pour `globalColumnRenames`, reprends celles de `column-rules.json` actuel.
Pour `resourceEntityTypes`, reprends le contenu de `resource-columns.json` actuel.

### 3. Refactorer `Core/Shared/ConfigLoader.ps1`

Le ConfigLoader doit maintenant :

1. Charger `db-schema.json` (source de vérité pour les tables, colonnes, FK)
2. Charger `overrides.json` (alias, renommages, resource entity types)
3. Charger `operator.json` (inchangé)
4. Fusionner les deux au chargement

**L'interface publique du ConfigLoader ne doit PAS changer.** Les méthodes suivantes doivent continuer à fonctionner exactement comme avant :

- `GetTableMapping($entityName)` → retourne `@{ tableName; alias; allowedFields }` 
  - `tableName` vient de `overrides.json` entityAliases (avec le préfixe `[dbo].[...]`)
  - `alias` vient de `overrides.json` entityAliases
  - `allowedFields` est maintenant généré dynamiquement depuis `db-schema.json` : la liste réelle des colonnes de la table

- `IsFieldAllowed($entityName, $fieldName)` → vérifie contre la vraie liste de colonnes de `db-schema.json`

- `GetColumnDbName($entityName, $fieldName)` → même logique qu'avant (overrides entity > resource columns > globalRenames > FK auto-rename > passthrough)

- `GetNavProp($entityName, $navPropName)` → **c'est ici le gros changement** :
  - D'abord chercher dans `overrides.json` s'il y a une surcharge manuelle
  - Sinon, déduire la relation depuis les FK de `db-schema.json` :
    - Chercher une colonne `{navPropName}_Id` dans la table de l'entity
    - Si elle a une FK déclarée, utiliser la table référencée comme targetTable
    - Appliquer les conventions : `localKey = "{navPropName}_Id"`, `foreignKey = "Id"`
  - Si rien trouvé, retourner `$null` comme avant

- `GetResourceEntityConfig($entityName)` → cherche dans `overrides.json` resourceEntityTypes (même logique qu'avant)

### 4. Supprimer les fichiers devenus obsolètes

Une fois le refactoring terminé :
- Supprimer `Configs/Default/database-mapping.json` (remplacé par `db-schema.json` + `overrides.json`)
- Supprimer `Configs/Default/join-patterns.json` (les FK de `db-schema.json` + surcharges dans `overrides.json`)
- Supprimer `Configs/Default/column-rules.json` (migré dans `overrides.json`)
- Supprimer `Configs/Default/resource-columns.json` (migré dans `overrides.json`)
- Garder `Configs/Default/operator.json` tel quel

### 5. Ce qui ne doit PAS changer

- `Core/SqueryToSql/Lexer.ps1` — aucun changement
- `Core/SqueryToSql/Parser.ps1` — aucun changement
- `Core/SqueryToSql/Validator.ps1` — aucun changement (il utilise déjà les méthodes du ConfigLoader)
- `Core/SqueryToSql/Transformer.ps1` — aucun changement (idem)
- `Core/SQuery-SQL-Translator.psm1` — aucun changement sauf si le chemin des configs change
- `SQuery-To-SQL.ps1` — aucun changement

## Contraintes

- PowerShell 5.1+ (Windows PowerShell, pas uniquement pwsh)
- Pas de dépendances externes (pas de modules à installer)
- Les tests existants dans `Tests/` doivent continuer à passer
- Le Custom overlay (`Configs/Custom/resource-columns.json`) doit continuer à fonctionner

## Ordre de travail suggéré

1. Créer `Import-DbSchema.ps1` et générer `db-schema.json` à partir des données que je fournirai
2. Créer `overrides.json` en migrant les valeurs des anciens fichiers
3. Refactorer `ConfigLoader.ps1` pour charger les nouveaux fichiers
4. Vérifier que les méthodes publiques retournent les mêmes résultats qu'avant
5. Supprimer les anciens fichiers
6. Lancer les tests
