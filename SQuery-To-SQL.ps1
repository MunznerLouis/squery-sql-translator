# SQuery-To-SQL.ps1
# Interactive launcher for SQuery-SQL-Translator.
# Provides a menu to translate SQuery URLs or configure Resource EntityTypes.

$ErrorActionPreference = 'Stop'

# Import the module
try {
    Import-Module "$PSScriptRoot\Core\SQuery-SQL-Translator.psm1" -Force
} catch {
    Write-Host "Failed to load module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Check if Custom resource-columns.json exists
$configRoot = Join-Path $PSScriptRoot 'Configs'
$customRcPath = Join-Path $configRoot 'Custom\resource-columns.json'

function Show-MainMenu {
    Write-Host ''
    Write-Host '=======================================' -ForegroundColor Cyan
    Write-Host ' SQuery-SQL-Translator' -ForegroundColor Cyan
    Write-Host '=======================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] Translate SQuery URL to SQL' -ForegroundColor White
    Write-Host '  [2] Configure Resource EntityTypes' -ForegroundColor White
    Write-Host '  [3] Exit' -ForegroundColor White
    Write-Host ''
}

function Invoke-TranslateLoop {
    # Warn if no custom config
    if (-not (Test-Path $customRcPath)) {
        Write-Host ''
        Write-Host '  Note: No custom resource-columns.json found.' -ForegroundColor Yellow
        Write-Host '  Resource EntityTypes will use the Default config.' -ForegroundColor Yellow
        Write-Host '  Run option [2] to import your project EntityTypes.' -ForegroundColor Yellow
        Write-Host ''
    }

    while ($true) {
        Write-Host ''
        $url = (Read-Host '  Enter SQuery URL (or "back" to return)').Trim('" ')

        if ([string]::IsNullOrWhiteSpace($url) -or $url -eq 'back') {
            return
        }

        try {
            $result = Convert-SQueryToSql -Url $url -WarningVariable wv 3>$null

            Write-Host ''
            if ($wv) {
                foreach ($w in $wv) {
                    Write-Host "  WARNING: $w" -ForegroundColor Yellow
                }
            }

            Write-Host '  --- SQL Output ---' -ForegroundColor Cyan
            Write-Host ''
            # Indent each line of the SQL for readability
            $result.Query.Split("`n") | ForEach-Object {
                Write-Host "    $_" -ForegroundColor Green
            }
            Write-Host ''

            if ($result.Parameters -and $result.Parameters.Count -gt 0) {
                Write-Host '  --- Parameters ---' -ForegroundColor Cyan
                foreach ($p in $result.Parameters.GetEnumerator()) {
                    Write-Host "    @$($p.Key) = $($p.Value)" -ForegroundColor Gray
                }
                Write-Host ''
            }
        } catch {
            Write-Host ''
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# --- Main loop ---
while ($true) {
    Show-MainMenu
    $choice = (Read-Host '  Enter choice (1-3)').Trim()

    switch ($choice) {
        '1' {
            Invoke-TranslateLoop
        }
        '2' {
            Initialize-Workspace
        }
        '3' {
            Write-Host ''
            Write-Host '  Goodbye!' -ForegroundColor Cyan
            Write-Host ''
            exit 0
        }
        default {
            Write-Host "  Invalid choice '$choice'." -ForegroundColor Yellow
        }
    }
}
