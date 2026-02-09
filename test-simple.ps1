# Test script for SQuery-SQL-Translator

Import-Module ./Core/SQuery-SQL-Translator.psd1 -Force

Write-Host "`n=== Test 1: Simple SELECT query ===" -ForegroundColor Cyan
$result1 = Convert-SQueryToSql -Url "http://api/User?select=Id,Name,Email"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result1.Query
Write-Host "`nParameters:" -ForegroundColor Yellow
$result1.Parameters

Write-Host "`n=== Test 2: Filter with CONTAINS ===" -ForegroundColor Cyan
$result2 = Convert-SQueryToSql -Url "http://api/User?filter[Name]=contains:john&select=Id,Name"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result2.Query
Write-Host "`nParameters:" -ForegroundColor Yellow
$result2.Parameters.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" }

Write-Host "`n=== Test 3: Multiple filters ===" -ForegroundColor Cyan
$result3 = Convert-SQueryToSql -Url "http://api/User?filter[Active]=1&filter[Age]=gt:18&sort=-CreatedDate"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result3.Query
Write-Host "`nParameters:" -ForegroundColor Yellow
$result3.Parameters.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" }

Write-Host "`n=== Test 4: IN operator ===" -ForegroundColor Cyan
$result4 = Convert-SQueryToSql -Url "http://api/User?filter[Id]=in:1,2,3,4,5"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result4.Query
Write-Host "`nParameters:" -ForegroundColor Yellow
$result4.Parameters.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" }

Write-Host "`n=== Test 5: Pagination ===" -ForegroundColor Cyan
$result5 = Convert-SQueryToSql -Url "http://api/User?limit=10&offset=20&sort=Name"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result5.Query

Write-Host "`n=== Test 6: Real Scenario Mode ===" -ForegroundColor Cyan
$result6 = Convert-SQueryToSql -Url "http://localhost:5000/api/ProvisioningPolicy/ResourceNavigationRule?api-version=1.0&squery=join+Property+prop+join+Resource+re+join+SingleRole+sr+join+ResourceType+rt+join+Policy+Policy+join+Policy.SimulationPolicy+PolicySimulationPolicy+top+5+select+Id,+ResourceId,+IsDenied,+Type,+prop.DisplayName,+prop.Identifier,+re.InternalDisplayName,+sr.DisplayName,+sr.FullName,+rt.DisplayName,+rt.FullName+where+((EntityTypeId+%3D2015+AND+PolicySimulationPolicy.Id+%3D+null)+AND+re.InternalDisplayName%25%3D%25%22DN%22)+order+by+ResourceId+asc,+Id+asc&Path=%2FProvisioningPolicy%2FResourceNavigationRule%2FQuery&QueryRootEntityType=ResourceNavigationRule"
Write-Host "Query:" -ForegroundColor Yellow
Write-Host $result6.Query



Write-Host "`n=== All tests completed successfully! ===" -ForegroundColor Green
