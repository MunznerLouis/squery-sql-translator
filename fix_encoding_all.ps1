$root = 'C:\Users\munzn\Desktop\Git_repos\squery-sql-translator'
$files = Get-ChildItem $root -Recurse -Include '*.ps1','*.psm1','*.psd1' |
    Where-Object { $_.FullName -notmatch '\\fix_encoding|\\syntax_check|\\test_pipeline' }

foreach ($file in $files) {
    $raw = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $hasNonAscii = $content -match '[^\x00-\x7F]'

    if (-not $hasBom -or $hasNonAscii) {
        $content = $content -replace [char]0x2500, '-'
        $content = $content -replace [char]0x2502, '|'
        $content = $content -replace [char]0x2014, '-'
        $content = $content -replace [char]0x2013, '-'
        $content = $content -replace [char]0x2018, "'"
        $content = $content -replace [char]0x2019, "'"
        [System.IO.File]::WriteAllText($file.FullName, $content, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "Fixed: $($file.Name) (was BOM=$hasBom, nonAscii=$hasNonAscii)"
    } else {
        Write-Host "OK:    $($file.Name)"
    }
}

Write-Host "`nRunning syntax check on all PS1/PSM1 files..."
Get-ChildItem $root -Recurse -Include '*.ps1','*.psm1' |
    Where-Object { $_.FullName -notmatch '\\fix_encoding|\\syntax_check|\\test_pipeline' } |
    ForEach-Object {
        $errors = [System.Management.Automation.Language.ParseError[]]@()
        $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
        if ($errors.Count -eq 0) {
            Write-Host "  PASS: $($_.Name)" -ForegroundColor Green
        } else {
            Write-Host "  FAIL: $($_.Name)" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host "    Line $($_.Extent.StartLineNumber): $($_.Message)" }
        }
    }
