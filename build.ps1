#!/usr/bin/env pwsh
# Build patched WindowsTerminal.exe and wt.exe

param(
    [string]$Platform = 'x64',
    [string]$Configuration = 'Release',
    [switch]$SkipPatch
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$terminalDir = Join-Path $repoRoot 'terminal'

# Apply patches unless skipped
if (-not $SkipPatch) {
    & "$repoRoot\apply-patches.ps1"
}

# Find MSBuild
$msbuild = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe `
    | Select-Object -First 1

if (-not $msbuild) {
    Write-Error "MSBuild not found. Install Visual Studio 2022 with C++ workload."
    exit 1
}

Write-Host "Using MSBuild: $msbuild" -ForegroundColor Cyan

Push-Location $terminalDir
try {
    # Restore NuGet packages
    Write-Host "`nRestoring packages..." -ForegroundColor Cyan
    & nuget restore OpenConsole.slnx

    # Build just the wt and WindowsTerminal projects
    Write-Host "`nBuilding WindowsTerminal ($Platform $Configuration)..." -ForegroundColor Cyan
    & $msbuild src\cascadia\WindowsTerminal\WindowsTerminal.vcxproj `
        /p:Platform=$Platform `
        /p:Configuration=$Configuration `
        /p:BuildProjectReferences=true `
        /m /v:minimal

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $msbuild src\cascadia\wt\wt.vcxproj `
        /p:Platform=$Platform `
        /p:Configuration=$Configuration `
        /p:BuildProjectReferences=false `
        /m /v:minimal

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $outDir = "bin\$Platform\$Configuration"
    Write-Host "`nBuild complete. Binaries in terminal\$outDir" -ForegroundColor Green
    Write-Host "  WindowsTerminal.exe"
    Write-Host "  wt.exe"
} finally {
    Pop-Location
}
