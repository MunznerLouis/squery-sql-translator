# Test loading files directly

Add-Type -AssemblyName System.Web

Write-Host "Loading files..." -ForegroundColor Cyan
. './Core/Shared/ConfigLoader.ps1'
Write-Host "  ConfigLoader.ps1 loaded"

. './Core/SqueryToSql/Lexer.ps1'
Write-Host "  Lexer.ps1 loaded"

. './Core/SqueryToSql/Parser.ps1'
Write-Host "  Parser.ps1 loaded"

. './Core/SqueryToSql/Validator.ps1'
Write-Host "  Validator.ps1 loaded"

. './Core/SqueryToSql/Transformer.ps1'
Write-Host "  Transformer.ps1 loaded"

Write-Host "`nTesting SqlQueryBuilder creation..." -ForegroundColor Cyan
$builder = [SqlQueryBuilder]::new()
Write-Host "SqlQueryBuilder created successfully!"

Write-Host "`nAvailable methods:" -ForegroundColor Cyan
$builder.GetType().GetMethods() | Where-Object { $_.DeclaringType.Name -eq 'SqlQueryBuilder' } | ForEach-Object {
    Write-Host "  $($_.Name)"
}
