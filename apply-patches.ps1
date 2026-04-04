#!/usr/bin/env pwsh
# Apply all patches to the terminal submodule

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$terminalDir = Join-Path $repoRoot 'terminal'
$patchesDir = Join-Path $repoRoot 'patches'

Push-Location $terminalDir
try {
    foreach ($patch in (Get-ChildItem $patchesDir -Filter '*.patch' | Sort-Object Name)) {
        Write-Host "Applying $($patch.Name)..." -ForegroundColor Cyan
        # --ignore-whitespace makes git treat \r as trailing whitespace, so a
        # LF patch applies cleanly against CRLF files (and vice versa).
        git apply --ignore-whitespace --check $patch.FullName
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Patch $($patch.Name) does not apply cleanly. The upstream terminal repo may have changed."
            exit 1
        }
        git apply --ignore-whitespace $patch.FullName
        Write-Host "  OK" -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host "`nAll patches applied." -ForegroundColor Green
