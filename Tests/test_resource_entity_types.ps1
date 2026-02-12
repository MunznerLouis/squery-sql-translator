# test_resource_entity_types.ps1
# Tests for Resource EntityType root entity support (Phase 2)

Import-Module "$PSScriptRoot\..\Core\SQuery-SQL-Translator.psm1" -Force

$pass = 0; $fail = 0

function Test-Case {
    param([string]$Label, [string]$SQuery, [string]$RootEntity, [string]$ExpectContains, [string]$ExpectNotContains = $null)
    Write-Host "`n=== $Label ==="
    try {
        $fakeUrl = "http://localhost:5000/api/up/$RootEntity`?squery=" + [System.Uri]::EscapeDataString($SQuery) + "&QueryRootEntityType=$RootEntity"
        $result = Convert-SQueryToSql -Url $fakeUrl
        Write-Host $result.Query
        $ok = $result.Query.Contains($ExpectContains)
        if ($ok -and $ExpectNotContains) {
            $ok = -not $result.Query.Contains($ExpectNotContains)
            if (-not $ok) { Write-Host "FAIL: query contains '$ExpectNotContains' but should not" -ForegroundColor Red }
        }
        if ($ok) {
            Write-Host "PASS" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "FAIL: expected to contain '$ExpectContains'" -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
        $script:fail++
    }
}

# Test 1: Directory_FR_User root - simple select, should get UM_EntityTypes INNER JOIN
Test-Case `
    -Label "1. Directory_FR_User root - EntityType INNER JOIN injected" `
    -SQuery "select Id, DisplayName, Identifier" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "INNER JOIN [dbo].[UM_EntityTypes]"

# Test 2: Directory_FR_User root - DisplayName maps to CC column
Test-Case `
    -Label "2. Directory_FR_User DisplayName -> CC column" `
    -SQuery "select DisplayName, Identifier" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains ".CC" `
    -ExpectNotContains "DisplayName_L1"

# Test 3: Directory_FR_User root - FROM should be UR_Resources
Test-Case `
    -Label "3. Directory_FR_User FROM -> UR_Resources" `
    -SQuery "select Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "FROM [dbo].[UR_Resources]"

# Test 4: Directory_FR_User + PresenceState join (double JOIN)
Test-Case `
    -Label "4. Directory_FR_User PresenceState join (double JOIN)" `
    -SQuery "join PresenceState ps select Id, ps.Id, PresenceState_Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "UM_EntityTypes] ps_et ON ps_et.Identifier = 'PresenceState'"

# Test 5: Directory_FR_User + PresenceState - second JOIN on UR_Resources filtered by Type
Test-Case `
    -Label "5. Directory_FR_User PresenceState second JOIN filters by Type" `
    -SQuery "join PresenceState ps select Id, ps.Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "ps.Type = ps_et.Id"

# Test 6: Directory_FR_User + Op_MainRecord_Organization join (single JOIN)
Test-Case `
    -Label "6. Directory_FR_User Op_MainRecord_Organization simple JOIN" `
    -SQuery "join Op_MainRecord_Organization org select Id, org.Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] org"

# Test 7: Workday_Person_FR root - EntityType INNER JOIN injected
Test-Case `
    -Label "7. Workday_Person_FR root - EntityType INNER JOIN" `
    -SQuery "select Id, FirstName, LastName" `
    -RootEntity "Workday_Person_FR" `
    -ExpectContains "INNER JOIN [dbo].[UM_EntityTypes]"

# Test 8: Workday_Person_FR Manager join
Test-Case `
    -Label "8. Workday_Person_FR Manager join" `
    -SQuery "join Manager mgr select Id, mgr.Id" `
    -RootEntity "Workday_Person_FR" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] mgr ON"

# Test 9: SAP_Person root
Test-Case `
    -Label "9. SAP_Person root - FROM UR_Resources + EntityType JOIN" `
    -SQuery "select Id, logon, surname" `
    -RootEntity "SAP_Person" `
    -ExpectContains "FROM [dbo].[UR_Resources]"

# Test 10: Directory_FR_User with WHERE
Test-Case `
    -Label "10. Directory_FR_User WHERE on C-column (PresenceState_Id)" `
    -SQuery "select Id where PresenceState_Id = 42" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains ".C40 = 42"

Write-Host "`n=========================================="
Write-Host "Results: $pass passed, $fail failed"
