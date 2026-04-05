#!/usr/bin/env pwsh
# start-session.ps1
# Starts psmux and the wt-psmux sync daemon together.
#
# Usage:
#   ./start-session.ps1 [-Session <name>] [-WtWindow <id>]
#
# What it does:
#   1. Starts psmux (new session or attaches to an existing one)
#   2. Launches psmux-sync.ps1 in the background to keep WT tabs in sync
#   3. When psmux exits, kills the sync daemon

param(
    [string]$Session = "main",
    [int]$WtWindow = 0
)

$here = $PSScriptRoot

# Check if session already exists
& psmux has-session -t $Session 2>$null
$sessionExists = $LASTEXITCODE -eq 0

# For a new session: create it detached first so the daemon can connect to it.
# For an existing session: daemon attaches to what's already there.
if (-not $sessionExists) {
    & psmux new-session -d -s $Session
}

# Start sync daemon in background. Use -CreateTabs only for fresh sessions.
$syncArgs = @(
    "-File", "$here\psmux-sync.ps1",
    "-Session", $Session,
    "-WtWindow", $WtWindow
)
if (-not $sessionExists) {
    $syncArgs += "-CreateTabs"
}

$daemon = Start-Process pwsh -ArgumentList $syncArgs -PassThru -WindowStyle Hidden
Write-Host "psmux-sync started (pid $($daemon.Id))"

try {
    # Attach to the session (now guaranteed to exist)
    & psmux attach-session -t $Session
} finally {
    # Clean up daemon when psmux exits
    if (-not $daemon.HasExited) {
        $daemon.Kill()
        Write-Host "psmux-sync stopped."
    }
}
