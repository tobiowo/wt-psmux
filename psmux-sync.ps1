#!/usr/bin/env pwsh
# psmux-sync.ps1
# Syncs psmux windows to Windows Terminal tabs via psmux control mode.
#
# Usage:
#   ./psmux-sync.ps1 [-Session <name>] [-WtWindow <id>] [-CreateTabs]
#
# Prerequisites:
#   - psmux on PATH
#   - patched wt.exe (wt-psmux) on PATH or in Windows Terminal install dir
#
# On startup, queries psmux for the current window list and assumes WT tabs
# are already open in the same order. Use -CreateTabs to have the daemon
# create WT tabs for each existing psmux window instead.

param(
    # psmux session name to attach to. Defaults to the first/current session.
    [string]$Session = "",

    # Windows Terminal window ID to sync tabs in.
    [int]$WtWindow = 0,

    # If set, create a new WT tab for each existing psmux window on startup
    # rather than assuming tabs already exist.
    [switch]$CreateTabs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

# Ordered list of psmux window IDs. The position in this list equals the
# 0-based WT tab index for that window.
$windowOrder = [System.Collections.Generic.List[string]]::new()

# Window IDs that have been added but not yet received a name (first rename
# event). We buffer these to open WT tabs with the right title.
$pendingAdds = [System.Collections.Generic.HashSet[string]]::new()

# ---------------------------------------------------------------------------
# WT helpers
# ---------------------------------------------------------------------------

function Invoke-Wt([string[]]$WtArgs) {
    & wt -w $WtWindow @WtArgs
}

function Open-WtTab([string]$Title) {
    $args = @("nt", "--suppressApplicationTitle")
    if ($Title) { $args += @("--title", $Title) }
    Invoke-Wt $args
}

function Close-WtTab([int]$Index) {
    Invoke-Wt @("close-tab", "-t", $Index.ToString())
}

function Rename-WtTab([int]$Index, [string]$Title) {
    Invoke-Wt @("rename-tab", "-t", $Index.ToString(), $Title)
}

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

function On-WindowAdd([string]$Id) {
    # Buffer the add — we'll open the tab when we get the first rename (which
    # carries the initial window name). If no rename arrives, we open untitled.
    $null = $pendingAdds.Add($Id)
    Write-Host "  psmux: window-add $Id (waiting for name)"
}

function On-WindowRenamed([string]$Id, [string]$Name) {
    if ($pendingAdds.Contains($Id)) {
        # This is the initial name for a newly added window.
        $null = $pendingAdds.Remove($Id)
        $index = $windowOrder.Count
        $windowOrder.Add($Id)
        Open-WtTab $Name
        Write-Host "  wt:    opened tab $index for $Id ('$Name')"
    } else {
        $index = $windowOrder.IndexOf($Id)
        if ($index -lt 0) { Write-Warning "rename: unknown window $Id"; return }
        Rename-WtTab $index $Name
        Write-Host "  wt:    renamed tab $index for $Id to '$Name'"
    }
}

function On-WindowClose([string]$Id) {
    # Flush any pending add that never got a name (window opened then closed fast)
    if ($pendingAdds.Contains($Id)) {
        $null = $pendingAdds.Remove($Id)
        Write-Host "  psmux: window-close $Id (was pending, no tab to close)"
        return
    }

    $index = $windowOrder.IndexOf($Id)
    if ($index -lt 0) { Write-Warning "close: unknown window $Id"; return }
    $windowOrder.RemoveAt($index)
    Close-WtTab $index
    Write-Host "  wt:    closed tab $index for $Id"
}

# ---------------------------------------------------------------------------
# Startup: build initial window map
# ---------------------------------------------------------------------------

function Initialize-WindowMap {
    $listArgs = @("list-windows", "-F", "#{window_id} #{window_name}")
    if ($Session) { $listArgs = @("-t", $Session) + $listArgs }

    $lines = & psmux @listArgs 2>&1
    $windows = @()
    foreach ($line in $lines) {
        if ($line -match '^(@\d+)\s+(.*)$') {
            $windows += [pscustomobject]@{ Id = $Matches[1]; Name = $Matches[2] }
        }
    }

    if ($windows.Count -eq 0) {
        Write-Host "No existing psmux windows found."
        return
    }

    if ($CreateTabs) {
        Write-Host "Creating $($windows.Count) WT tab(s) for existing psmux windows..."
        foreach ($w in $windows) {
            $index = $windowOrder.Count
            $windowOrder.Add($w.Id)
            Open-WtTab $w.Name
            Write-Host "  wt:    opened tab $index for $($w.Id) ('$($w.Name)')"
        }
    } else {
        Write-Host "Mapping $($windows.Count) existing psmux window(s) to WT tabs (assuming tabs already open in order):"
        foreach ($w in $windows) {
            $index = $windowOrder.Count
            $windowOrder.Add($w.Id)
            Write-Host "  tab $index ← $($w.Id) ('$($w.Name)')"
        }
    }
}

# ---------------------------------------------------------------------------
# Main: attach to control mode and parse events
# ---------------------------------------------------------------------------

Initialize-WindowMap

Write-Host ""
Write-Host "Attaching to psmux control mode ($($windowOrder.Count) window(s) mapped)..."
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$ccArgs = @("-CC")
if ($Session) { $ccArgs = @("-t", $Session) + $ccArgs }

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = "psmux"
$startInfo.Arguments = $ccArgs -join " "
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardInput  = $true   # keep stdin open so psmux doesn't exit
$startInfo.UseShellExecute = $false

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $startInfo
$null = $proc.Start()

# Register Ctrl+C to clean up
$null = Register-EngineEvent PowerShell.Exiting -Action { $proc.Kill() }
try {
    [Console]::CancelKeyPress += {
        param($s, $e)
        $e.Cancel = $true
        $proc.Kill()
    }
} catch {}

try {
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if (-not $line) { continue }

        switch -Regex ($line) {
            # %window-add @N
            '^%window-add (@\d+)$' {
                On-WindowAdd $Matches[1]
            }

            # %window-close @N
            '^%window-close (@\d+)$' {
                On-WindowClose $Matches[1]
            }

            # %window-renamed @N <name>
            '^%window-renamed (@\d+) (.+)$' {
                On-WindowRenamed $Matches[1] $Matches[2]
            }

            # Silently ignore everything else (%begin, %end, %sessions-changed, etc.)
            default {
                # Uncomment to debug:
                # Write-Host "  [raw] $line"
            }
        }
    }
} finally {
    if (-not $proc.HasExited) { $proc.Kill() }
    Write-Host "psmux control mode disconnected."
}
