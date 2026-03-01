# tests.ps1
# All tests for SQuery-SQL-Translator: real URL translations, Resource EntityTypes, warnings & errors.

Import-Module "$PSScriptRoot\..\Core\SQuery-SQL-Translator.psm1" -Force

$pass = 0; $fail = 0

# ==========================================================================
# Test helpers
# ==========================================================================

function Test-Url {
    param([string]$Label, [string]$Url, [string]$ExpectContains = $null, [string]$ExpectNotContains = $null)
    Write-Host "`n=== $Label ==="
    try {
        $result = Convert-SQueryToSql -Url $Url -WarningVariable wv 3>$null
        if ($wv) {
            foreach ($w in $wv) { Write-Host "  WARN: $w" -ForegroundColor Yellow }
        }
        Write-Host $result.Query -ForegroundColor Green
        if ($ExpectContains -and -not $result.Query.Contains($ExpectContains)) {
            Write-Host "FAIL: expected to contain '$ExpectContains'" -ForegroundColor Red
            $script:fail++; return
        }
        if ($ExpectNotContains -and $result.Query.Contains($ExpectNotContains)) {
            Write-Host "FAIL: should not contain '$ExpectNotContains'" -ForegroundColor Red
            $script:fail++; return
        }
        Write-Host "PASS" -ForegroundColor Green
        $script:pass++
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

function Test-SQuery {
    param([string]$Label, [string]$SQuery, [string]$RootEntity, [string]$ExpectContains, [string]$ExpectNotContains = $null)
    $fakeUrl = "http://localhost:5000/api/up/$RootEntity`?squery=" + [System.Uri]::EscapeDataString($SQuery) + "&QueryRootEntityType=$RootEntity"
    Test-Url -Label $Label -Url $fakeUrl -ExpectContains $ExpectContains -ExpectNotContains $ExpectNotContains
}

function Test-Warning {
    param([string]$Label, [string]$SQuery, [string]$RootEntity, [string]$ExpectWarningContains)
    Write-Host "`n=== $Label ==="
    try {
        $fakeUrl = "http://localhost:5000/api/up/$RootEntity`?squery=" + [System.Uri]::EscapeDataString($SQuery) + "&QueryRootEntityType=$RootEntity"
        $result = Convert-SQueryToSql -Url $fakeUrl -WarningVariable wv 3>$null
        $allWarnings = ($wv | ForEach-Object { $_.ToString() }) -join "`n"
        if ($allWarnings -match [regex]::Escape($ExpectWarningContains)) {
            foreach ($w in $wv) { Write-Host "  WARNING: $w" -ForegroundColor Yellow }
            Write-Host "PASS" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "FAIL: expected warning containing '$ExpectWarningContains'" -ForegroundColor Red
            if ($allWarnings) { Write-Host "  Got: $allWarnings" -ForegroundColor Yellow }
            else { Write-Host "  No warnings produced" -ForegroundColor Yellow }
            $script:fail++
        }
    } catch {
        Write-Host "FAIL: threw error instead of warning: $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

function Test-Error {
    param([string]$Label, [string]$SQuery, [string]$RootEntity, [string]$ExpectErrorContains)
    Write-Host "`n=== $Label ==="
    try {
        $fakeUrl = "http://localhost:5000/api/up/$RootEntity`?squery=" + [System.Uri]::EscapeDataString($SQuery) + "&QueryRootEntityType=$RootEntity"
        $result = Convert-SQueryToSql -Url $fakeUrl -WarningVariable wv 3>$null 2>$null
        Write-Host "FAIL: expected an error but query succeeded" -ForegroundColor Red
        Write-Host "  Query: $($result.Query)" -ForegroundColor Yellow
        $script:fail++
    } catch {
        $errMsg = $_.Exception.Message -replace '^Failed to convert SQuery to SQL: ', '' -replace '^Query validation failed:\s*', ''
        if ($errMsg -match [regex]::Escape($ExpectErrorContains)) {
            Write-Host "  ERROR: $errMsg" -ForegroundColor Red
            Write-Host "PASS" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "FAIL: expected error containing '$ExpectErrorContains'" -ForegroundColor Red
            Write-Host "  Got: $errMsg" -ForegroundColor Yellow
            $script:fail++
        }
    }
}

# ==========================================================================
# SECTION 1: Real URL translations (12 tests)
# ==========================================================================
Write-Host "`n##########################################################" -ForegroundColor White
Write-Host " SECTION 1: Real URL Translations" -ForegroundColor White
Write-Host "##########################################################" -ForegroundColor White

Test-Url "1.1 Category - simple select + IS NULL + ORDER BY" `
    'http://localhost:5000/api/ProvisioningPolicy/Category?api-version=1.0&squery=select+Id,+Identifier,+DisplayName,+Description,+IsCollapsed,+ParentId,+PolicyId,+SingleRoleCounter,+CompositeRoleCounter,+ResourceTypeCounter+where+ParentId%3Dnull+order+by+Id+asc&QueryRootEntityType=Category'

Test-Url "1.2 AssignedSingleRole - chained r.Policy, OR WorkflowState" `
    'http://localhost:5000/api/ProvisioningPolicy/AssignedSingleRole?api-version=1.0&squery=join+Role+r+join+r.Policy+rp+join+WorkflowInstance+w+join+Owner+of+type+Directory_FR_User+Owner+join+ParametersContext+pc+top+6+select+Id,+StartDate,+EndDate,+IsDenied,+WorkflowState,+WorkflowInstanceId,+RoleId,+OwnerId,+OwnerType,+ParametersContextId,+IsIndirect,+r.DisplayName,+r.ApprovalWorkflowType,+r.FullName,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+rp.CommentActivationOnApproveInReview,+rp.CommentActivationOnDeclineInReview,pc.DisplayName+where+((OwnerType%3D2015+and+IsIndirect%3Dfalse)+AND+(WorkflowState%3D8+OR+WorkflowState%3D9+OR+WorkflowState%3D10))+order+by+WorkflowInstanceId+desc,+OwnerId+desc,+Id+desc&QueryRootEntityType=AssignedSingleRole'

Test-Url "1.3 AssignedResourceType - range WHERE (( > AND < ) OR > )" `
    'http://localhost:5000/api/ProvisioningPolicy/AssignedResourceType?api-version=1.0&squery=join+Role+r+join+WorkflowInstance+w+join+ParametersContext+pc+join+Owner+of+type+Directory_FR_User+Owner+top+4+select+Id,+StartDate,+EndDate,+ProvisioningState,+WorkflowState,+IsDenied,+RoleId,+ResourceId,+OwnerType,+OwnerId,+WorkflowInstanceId,+ParametersContextId,+r.BlockProvisioning,+r.FullName,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+Owner.Id,pc.DisplayName+where+(OwnerType%3D2015+AND+((ProvisioningReviewFilter%3E0+AND+ProvisioningReviewFilter%3C16)+OR+ProvisioningReviewFilter%3E31))+order+by+WorkflowInstanceId+desc,+OwnerId+desc,+Id+desc&QueryRootEntityType=AssignedResourceType'

Test-Url "1.4 AssignedCompositeRole - chained r.Policy, WorkflowState=1" `
    'http://localhost:5000/api/ProvisioningPolicy/AssignedCompositeRole?api-version=1.0&squery=join+Role+r+join+r.Policy+rp+join+WorkflowInstance+w+join+Owner+of+type+Directory_FR_User+Owner+join+ParametersContext+pc+top+6+select+Id,+StartDate,+EndDate,+IsDenied,+WorkflowState,+WorkflowInstanceId,+RoleId,+OwnerId,+OwnerType,+ParametersContextId,+IsIndirect,+r.DisplayName,+r.FullName,+r.Description,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+WhenCreated,pc.DisplayName+where+((OwnerType%3D2015+and+IsIndirect%3Dfalse)+AND+(WorkflowState%3D1))+order+by+WhenCreated+asc,+OwnerId+asc,+Id+asc&QueryRootEntityType=AssignedCompositeRole'

Test-Url "1.5 Job - Agent + LastJobInstance, no WHERE" `
    'http://localhost:5000/api/Job/Job?api-version=3.0&squery=join+Agent+a+join+LastJobInstance+lji+select+Id,+Identifier,+DisplayName,+UserStartDenied,+LogLevel,+IsIncremental,+a.URI,+lji.State,+lji.Retry+order+by+DisplayName+asc&QueryRootEntityType=Job'

Test-Url "1.6 JobInstance - User + Job, WHERE JobId=1019" `
    'http://localhost:5000/api/Job/JobInstance?api-version=1.0&squery=join+User+u+join+Job+j+top+7+select+Id,+EndDate,+StartDate,+State,+CurrentLaunch,+TotalLaunch,+Retry,+u.Id,+u.InternalDisplayName,+j.IsConnectorJob+where+(JobId+%3D+1019)+order+by+StartDate+desc,+Id+desc&QueryRootEntityType=JobInstance'

Test-Url "1.7 Connector - nested co.Package, etm.EntityType" `
    'http://localhost:5000/api/Connectors/Connector/2004?api-version=2.0&squery=join+Agent+a+join+Connections+co+join+co.Package+p+join+EntityTypeMappings+etm+join+etm.EntityType+et+select+Identifier,+DisplayName,+a.DisplayName,+IsDeactivated,+co.Identifier,+co.DisplayName,+p.Identifier,+p.DisplayName,+et.Identifier,+et.DisplayName&QueryRootEntityType=Connector'

Test-Url "1.8 Universe - minimal select + order by" `
    'http://localhost:5000/api/Universes/Universe?api-version=1.0&squery=select+Id,Identifier,DisplayName,IsHistoryDisabled+order+by+DisplayName+asc&QueryRootEntityType=Universe'

Test-Url "1.9 CompositeRoleRule - CreatedBy + ChangedBy joins" `
    'http://localhost:5000/api/ProvisioningPolicy/CompositeRoleRule/25001?api-version=1.0&squery=join+Policy+p+join+CreatedBy+lcb+join+ChangedBy+lub+select+p.DisplayName,WhenCreated,WhenChanged,lcb.InternalDisplayName,lub.InternalDisplayName&QueryRootEntityType=CompositeRoleRule'

Test-Url "1.10 ResourceClassificationRule - ResourceType join + WHERE EntityTypeId" `
    'http://localhost:5000/api/ProvisioningPolicy/ResourceClassificationRule?api-version=1.0&squery=join+ResourceType+rt+top+8+select+PolicyId,+TargetExpression,+SourceMatchedConfidenceLevel,+ResourceTypeIdentificationConfidenceLevel,+ResourceTypeId,+rt.DisplayName,+rt.FullName,+rt.TargetEntityTypeId,+rt.SourceEntityTypeId+where+(EntityTypeId+%3D2015)+order+by+ResourceTypeId+asc,+Id+asc&QueryRootEntityType=ResourceClassificationRule'

Test-Url "1.11 Policy - SimulationPolicy.Id=null AND ProvisioningPolicy.Id=null" `
    'http://localhost:5000/api/ProvisioningPolicy/Policy?api-version=1.0&squery=join+SimulationPolicy+SimulationPolicy+join+ProvisioningPolicy+ProvisioningPolicy+select+Identifier,+DisplayName,+PolicySimulationId,+PolicyProvisioningId+where+(SimulationPolicy.Id+%3D+null+AND+ProvisioningPolicy.Id+%3D+null)&QueryRootEntityType=Policy'

Test-Url "1.12 ResourceCorrelationRule - chained Policy.SimulationPolicy + LIKE" `
    'http://localhost:5000/api/ProvisioningPolicy/ResourceCorrelationRule?api-version=1.0&squery=join+ResourceType+rt+join+SourceBinding+sb+join+TargetBinding+tb+join+Policy+Policy+join+Policy.SimulationPolicy+PolicySimulationPolicy+top+8+select+PolicyId,+SourceExpression,+TargetExpression,+SourceMatchedConfidenceLevel,+ResourceTypeId,+rt.DisplayName,+rt.FullName,+rt.SourceEntityTypeId,+rt.TargetEntityTypeId,+sb.Path,+tb.Path+where+((EntityTypeId+%3D2015+AND+PolicySimulationPolicy.Id+%3D+null)+AND+rt.FullName%25%3D%25%2231%22)+order+by+ResourceTypeId+asc,+Id+asc&Path=%2FProvisioningPolicy%2FResourceCorrelationRule%2FQuery&QueryRootEntityType=ResourceCorrelationRule'

# ==========================================================================
# SECTION 2: Resource EntityType support (10 tests)
# ==========================================================================
Write-Host "`n##########################################################" -ForegroundColor White
Write-Host " SECTION 2: Resource EntityTypes (WHERE Type=N)" -ForegroundColor White
Write-Host "##########################################################" -ForegroundColor White

Test-SQuery "2.1 Directory_FR_User - WHERE Type=2015 injected" `
    -SQuery "select Id, DisplayName, Identifier" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "dfru.Type = 2015" `
    -ExpectNotContains "INNER JOIN [dbo].[UM_EntityTypes]"

Test-SQuery "2.2 Directory_FR_User - DisplayName -> CC column" `
    -SQuery "select DisplayName, Identifier" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains ".CC" `
    -ExpectNotContains "DisplayName_L1"

Test-SQuery "2.3 Directory_FR_User - FROM UR_Resources" `
    -SQuery "select Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "FROM [dbo].[UR_Resources]"

Test-SQuery "2.4 Directory_FR_User - PresenceState LEFT JOIN UR_Resources" `
    -SQuery "join PresenceState ps select Id, ps.Id, PresenceState_Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] ps ON dfru.PresenceState_Id = ps.Id"

Test-SQuery "2.5 Directory_FR_User - PresenceState no UM_EntityTypes" `
    -SQuery "join PresenceState ps select Id, ps.Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] ps" `
    -ExpectNotContains "UM_EntityTypes"

Test-SQuery "2.6 Directory_FR_User - Owner join via resourceNavigationProperties" `
    -SQuery "join Owner ow select Id, ow.Id" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] ow ON dfru.Owner_Id = ow.Id"

Test-SQuery "2.7 Workday_Person_FR - WHERE Type=2045" `
    -SQuery "select Id, FirstName, LastName" `
    -RootEntity "Workday_Person_FR" `
    -ExpectContains "wpfr.Type = 2045" `
    -ExpectNotContains "INNER JOIN [dbo].[UM_EntityTypes]"

Test-SQuery "2.8 Workday_Person_FR - Owner join" `
    -SQuery "join Owner ow select Id, ow.Id" `
    -RootEntity "Workday_Person_FR" `
    -ExpectContains "LEFT JOIN [dbo].[UR_Resources] ow ON wpfr.Owner_Id = ow.Id"

Test-SQuery "2.9 SAP_Person - FROM UR_Resources + WHERE Type=2027" `
    -SQuery "select Id, logon, surname" `
    -RootEntity "SAP_Person" `
    -ExpectContains "FROM [dbo].[UR_Resources]"

Test-SQuery "2.10 Directory_FR_User - WHERE Type filter prepended" `
    -SQuery "select Id where PresenceState_Id = 42" `
    -RootEntity "Directory_FR_User" `
    -ExpectContains "dfru.Type = 2015 AND (dfru.C40 = 42)"

# ==========================================================================
# SECTION 3: Warnings & Errors (10 tests)
# ==========================================================================
Write-Host "`n##########################################################" -ForegroundColor White
Write-Host " SECTION 3: Warnings and Errors" -ForegroundColor White
Write-Host "##########################################################" -ForegroundColor White

Test-Error "3.1 Unknown root entity -> error" `
    -SQuery "select Id" `
    -RootEntity "FakeEntity" `
    -ExpectErrorContains "is not mapped to any SQL table"

Test-Warning "3.2 Undefined nav prop -> warning (LEFT JOIN skipped)" `
    -SQuery "join FakeNavProp fnp select Id, fnp.Id" `
    -RootEntity "Category" `
    -ExpectWarningContains "the LEFT JOIN was skipped"

Test-Warning "3.3 Undefined nav prop -> fix hint (navigationPropertyOverrides)" `
    -SQuery "join FakeNavProp fnp select Id, fnp.Id" `
    -RootEntity "Category" `
    -ExpectWarningContains "navigationPropertyOverrides"

Test-Error "3.4 Undeclared alias in SELECT -> error" `
    -SQuery "select Id, xyz.Name" `
    -RootEntity "Category" `
    -ExpectErrorContains "is not declared"

Test-Error "3.5 Undeclared alias -> shows available aliases" `
    -SQuery "select Id, xyz.Name" `
    -RootEntity "Category" `
    -ExpectErrorContains "Available aliases:"

Test-Warning "3.6 Unknown field -> warning (not a known property)" `
    -SQuery "select Id, CompletelyFakeField" `
    -RootEntity "Category" `
    -ExpectWarningContains "is not a known property of entity"

Test-Warning "3.7 Unknown field -> suggests causes (nav prop / computed / typo)" `
    -SQuery "select Id, CompletelyFakeField" `
    -RootEntity "Category" `
    -ExpectWarningContains "navigation property, computed field, or typo"

Test-Error "3.8 Duplicate JOIN alias -> error" `
    -SQuery "join Policy p join Policy p select Id" `
    -RootEntity "Category" `
    -ExpectErrorContains "Each alias must be unique"

Test-Error "3.9 Chained join with undeclared parent -> error" `
    -SQuery "join x.Policy xp select Id" `
    -RootEntity "Category" `
    -ExpectErrorContains "is not declared"

# 3.10: Empty SQuery (needs raw URL with squery= empty)
Write-Host "`n=== 3.10 Empty SQuery -> warning (SELECT *) ==="
try {
    $url = "http://localhost:5000/api/up/Category?squery=&QueryRootEntityType=Category"
    $result = Convert-SQueryToSql -Url $url -WarningVariable wv 3>$null
    $allWarnings = ($wv | ForEach-Object { $_.ToString() }) -join "`n"
    if ($allWarnings -match 'SQuery string is empty') {
        Write-Host "PASS" -ForegroundColor Green
        $pass++
    } else {
        Write-Host "FAIL: expected warning about empty SQuery" -ForegroundColor Red
        if ($allWarnings) { Write-Host "  Got: $allWarnings" -ForegroundColor Yellow }
        $fail++
    }
} catch {
    Write-Host "FAIL: threw error instead of warning: $($_.Exception.Message)" -ForegroundColor Red
    $fail++
}

# ==========================================================================
# Summary
# ==========================================================================
Write-Host "`n==========================================================" -ForegroundColor White
Write-Host " TOTAL: $pass passed, $fail failed" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host "==========================================================" -ForegroundColor White
