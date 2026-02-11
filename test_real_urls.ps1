Import-Module "$PSScriptRoot\Core\SQuery-SQL-Translator.psm1" -Force

$pass = 0
$fail = 0
$warn = 0

function Test-Url {
    param([string]$Label, [string]$Url)
    Write-Host "`n=== $Label ===" -ForegroundColor Cyan
    try {
        $result = Convert-SQueryToSql -Url $Url -WarningVariable wv 3>$null
        if ($wv) {
            foreach ($w in $wv) { Write-Host "  WARN: $w" -ForegroundColor Yellow }
            $script:warn++
        }
        Write-Host $result.Query -ForegroundColor Green
        if ($result.Parameters.Count -gt 0) {
            $p = ($result.Parameters.GetEnumerator() | Sort-Object Name | ForEach-Object { "@$($_.Key)=$($_.Value)" }) -join ', '
            Write-Host "  Params: $p" -ForegroundColor DarkGray
        }
        $script:pass++
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

# ---------------------------------------------------------------------------
# 1. Category - simple SELECT, no joins, IS NULL, ORDER BY
# ---------------------------------------------------------------------------
Test-Url "1. Category - simple select + IS NULL" `
'http://localhost:5000/api/ProvisioningPolicy/Category?api-version=1.0&squery=select+Id,+Identifier,+DisplayName,+Description,+IsCollapsed,+ParentId,+PolicyId,+SingleRoleCounter,+CompositeRoleCounter,+ResourceTypeCounter+where+ParentId%3Dnull+order+by+Id+asc&QueryRootEntityType=Category'

# ---------------------------------------------------------------------------
# 2. AssignedSingleRole - chained join r.Policy rp, multiple OR conditions
# ---------------------------------------------------------------------------
Test-Url "2. AssignedSingleRole - chained r.Policy, OR WorkflowState" `
'http://localhost:5000/api/ProvisioningPolicy/AssignedSingleRole?api-version=1.0&squery=join+Role+r+join+r.Policy+rp+join+WorkflowInstance+w+join+Owner+of+type+Directory_FR_User+Owner+join+ParametersContext+pc+top+6+select+Id,+StartDate,+EndDate,+IsDenied,+WorkflowState,+WorkflowInstanceId,+RoleId,+OwnerId,+OwnerType,+ParametersContextId,+IsIndirect,+r.DisplayName,+r.ApprovalWorkflowType,+r.FullName,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+rp.CommentActivationOnApproveInReview,+rp.CommentActivationOnDeclineInReview,pc.DisplayName+where+((OwnerType%3D2015+and+IsIndirect%3Dfalse)+AND+(WorkflowState%3D8+OR+WorkflowState%3D9+OR+WorkflowState%3D10))+order+by+WorkflowInstanceId+desc,+OwnerId+desc,+Id+desc&QueryRootEntityType=AssignedSingleRole'

# ---------------------------------------------------------------------------
# 3. AssignedResourceType - complex nested WHERE with range conditions
# ---------------------------------------------------------------------------
Test-Url "3. AssignedResourceType - range WHERE (( > AND < ) OR > )" `
'http://localhost:5000/api/ProvisioningPolicy/AssignedResourceType?api-version=1.0&squery=join+Role+r+join+WorkflowInstance+w+join+ParametersContext+pc+join+Owner+of+type+Directory_FR_User+Owner+top+4+select+Id,+StartDate,+EndDate,+ProvisioningState,+WorkflowState,+IsDenied,+RoleId,+ResourceId,+OwnerType,+OwnerId,+WorkflowInstanceId,+ParametersContextId,+r.BlockProvisioning,+r.FullName,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+Owner.Id,pc.DisplayName+where+(OwnerType%3D2015+AND+((ProvisioningReviewFilter%3E0+AND+ProvisioningReviewFilter%3C16)+OR+ProvisioningReviewFilter%3E31))+order+by+WorkflowInstanceId+desc,+OwnerId+desc,+Id+desc&QueryRootEntityType=AssignedResourceType'

# ---------------------------------------------------------------------------
# 4. AssignedCompositeRole - chained r.Policy, reconciliation
# ---------------------------------------------------------------------------
Test-Url "4. AssignedCompositeRole - chained r.Policy, WorkflowState=1" `
'http://localhost:5000/api/ProvisioningPolicy/AssignedCompositeRole?api-version=1.0&squery=join+Role+r+join+r.Policy+rp+join+WorkflowInstance+w+join+Owner+of+type+Directory_FR_User+Owner+join+ParametersContext+pc+top+6+select+Id,+StartDate,+EndDate,+IsDenied,+WorkflowState,+WorkflowInstanceId,+RoleId,+OwnerId,+OwnerType,+ParametersContextId,+IsIndirect,+r.DisplayName,+r.FullName,+r.Description,+w.Id,+w.Identifier,+Owner.InternalDisplayName,+WhenCreated,pc.DisplayName+where+((OwnerType%3D2015+and+IsIndirect%3Dfalse)+AND+(WorkflowState%3D1))+order+by+WhenCreated+asc,+OwnerId+asc,+Id+asc&QueryRootEntityType=AssignedCompositeRole'

# ---------------------------------------------------------------------------
# 5. Job - Agent + LastJobInstance, no WHERE
# ---------------------------------------------------------------------------
Test-Url "5. Job - Agent + LastJobInstance, no WHERE" `
'http://localhost:5000/api/Job/Job?api-version=3.0&squery=join+Agent+a+join+LastJobInstance+lji+select+Id,+Identifier,+DisplayName,+UserStartDenied,+LogLevel,+IsIncremental,+a.URI,+lji.State,+lji.Retry+order+by+DisplayName+asc&QueryRootEntityType=Job'

# ---------------------------------------------------------------------------
# 6. JobInstance - User + Job joins, WHERE with integer value
# ---------------------------------------------------------------------------
Test-Url "6. JobInstance - User + Job, WHERE JobId=1019" `
'http://localhost:5000/api/Job/JobInstance?api-version=1.0&squery=join+User+u+join+Job+j+top+7+select+Id,+EndDate,+StartDate,+State,+CurrentLaunch,+TotalLaunch,+Retry,+u.Id,+u.InternalDisplayName,+j.IsConnectorJob+where+(JobId+%3D+1019)+order+by+StartDate+desc,+Id+desc&QueryRootEntityType=JobInstance'

# ---------------------------------------------------------------------------
# 7. Connector - nested join co.Package p + etm.EntityType et
# ---------------------------------------------------------------------------
Test-Url "7. Connector - nested co.Package, etm.EntityType" `
'http://localhost:5000/api/Connectors/Connector/2004?api-version=2.0&squery=join+Agent+a+join+Connections+co+join+co.Package+p+join+EntityTypeMappings+etm+join+etm.EntityType+et+select+Identifier,+DisplayName,+a.DisplayName,+IsDeactivated,+co.Identifier,+co.DisplayName,+p.Identifier,+p.DisplayName,+et.Identifier,+et.DisplayName&QueryRootEntityType=Connector'

# ---------------------------------------------------------------------------
# 8. Universe - simplest possible query: SELECT + ORDER BY, no WHERE, no JOIN
# ---------------------------------------------------------------------------
Test-Url "8. Universe - minimal select + order by" `
'http://localhost:5000/api/Universes/Universe?api-version=1.0&squery=select+Id,Identifier,DisplayName,IsHistoryDisabled+order+by+DisplayName+asc&QueryRootEntityType=Universe'

# ---------------------------------------------------------------------------
# 9. CompositeRoleRule - single-record query with CreatedBy + ChangedBy joins
# ---------------------------------------------------------------------------
Test-Url "9. CompositeRoleRule - CreatedBy + ChangedBy joins" `
'http://localhost:5000/api/ProvisioningPolicy/CompositeRoleRule/25001?api-version=1.0&squery=join+Policy+p+join+CreatedBy+lcb+join+ChangedBy+lub+select+p.DisplayName,WhenCreated,WhenChanged,lcb.InternalDisplayName,lub.InternalDisplayName&QueryRootEntityType=CompositeRoleRule'

# ---------------------------------------------------------------------------
# 10. ResourceClassificationRule - ResourceType join, WHERE EntityTypeId
# ---------------------------------------------------------------------------
Test-Url "10. ResourceClassificationRule - ResourceType join + WHERE EntityTypeId" `
'http://localhost:5000/api/ProvisioningPolicy/ResourceClassificationRule?api-version=1.0&squery=join+ResourceType+rt+top+8+select+PolicyId,+TargetExpression,+SourceMatchedConfidenceLevel,+ResourceTypeIdentificationConfidenceLevel,+ResourceTypeId,+rt.DisplayName,+rt.FullName,+rt.TargetEntityTypeId,+rt.SourceEntityTypeId+where+(EntityTypeId+%3D2015)+order+by+ResourceTypeId+asc,+Id+asc&QueryRootEntityType=ResourceClassificationRule'

# ---------------------------------------------------------------------------
# 11. Policy - SimulationPolicy + ProvisioningPolicy IS NULL WHERE check
# ---------------------------------------------------------------------------
Test-Url "11. Policy - SimulationPolicy.Id=null AND ProvisioningPolicy.Id=null" `
'http://localhost:5000/api/ProvisioningPolicy/Policy?api-version=1.0&squery=join+SimulationPolicy+SimulationPolicy+join+ProvisioningPolicy+ProvisioningPolicy+select+Identifier,+DisplayName,+PolicySimulationId,+PolicyProvisioningId+where+(SimulationPolicy.Id+%3D+null+AND+ProvisioningPolicy.Id+%3D+null)&QueryRootEntityType=Policy'

# ---------------------------------------------------------------------------
# 12. EntityTypeMapping - Connector + EntityType, WHERE c.Id != null
# ---------------------------------------------------------------------------
Test-Url "12. EntityTypeMapping - Connector + EntityType, WHERE != null" `
'http://localhost:5000/api/Connectors/EntityTypeMapping?api-version=1.0&squery=join+Connector+c+join+EntityType+et+select+c.Id,+c.DisplayName,+et.Id,+et.Identifier,+et.DisplayName+where+c.Id+!%3D+null&QueryRootEntityType=EntityTypeMapping'

# ---------------------------------------------------------------------------
Write-Host "`n==========================================" -ForegroundColor White
Write-Host "Results: $pass passed, $fail failed, $warn with warnings" -ForegroundColor $(if ($fail -gt 0) { 'Red' } elseif ($warn -gt 0) { 'Yellow' } else { 'Green' })
