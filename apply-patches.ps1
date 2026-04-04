#!/usr/bin/env pwsh
# Apply all patches to the terminal submodule

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$terminalDir = Join-Path $repoRoot 'terminal'
$patchesDir = Join-Path $repoRoot 'patches'

Push-Location $terminalDir
try {
    # Ensure files are checked out with LF so our LF-normalized patch applies
    # consistently regardless of core.autocrlf on the host.
    git config core.autocrlf false
    git checkout -- .

    foreach ($patch in (Get-ChildItem $patchesDir -Filter '*.patch' | Sort-Object Name)) {
        Write-Host "Applying $($patch.Name)..." -ForegroundColor Cyan
        git apply --check $patch.FullName
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Patch $($patch.Name) does not apply cleanly. The upstream terminal repo may have changed."
            exit 1
        }
        git apply $patch.FullName
        Write-Host "  OK" -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host "`nAll patches applied." -ForegroundColor Green
