# wt-psmux

A patched build of [Windows Terminal](https://github.com/microsoft/terminal) that adds CLI subcommands needed for programmatic tab management — specifically to enable native Windows Terminal tab sync with [psmux](https://github.com/marlocarlo/psmux) sessions.

## What this adds

Two new `wt.exe` subcommands on top of unmodified Windows Terminal:

```
wt close-tab [-t <index>]       # close a tab (active tab if no index given)
wt rename-tab [-t <index>] <title>  # rename a tab (active tab if no index given)
```

Also available as short aliases: `ct` and `rt`.

### Examples

```powershell
# Close the tab at index 2
wt -w 0 close-tab -t 2

# Close the currently active tab
wt -w 0 close-tab

# Rename the tab at index 1
wt -w 0 rename-tab -t 1 "my project"

# Rename the currently active tab
wt -w 0 rename-tab "build output"
```

## The goal: psmux ↔ Windows Terminal tab sync

[psmux](https://github.com/marlocarlo/psmux) exposes a [control mode](https://github.com/psmux/psmux/blob/master/docs/control-mode.md) (`psmux -CC`) that streams real-time session events — window creation, closing, renaming — over a structured text protocol. This is the same protocol as tmux control mode, which is what powers iTerm2's native tmux tab integration on macOS.

This project makes the same integration possible on Windows.

### How the sync daemon works

A small background process connects to psmux in control mode and maps psmux window events to `wt.exe` commands:

| psmux event | wt.exe command |
|---|---|
| `%window-add @N` | `wt -w 0 nt --title "<name>" --suppressApplicationTitle` |
| `%window-close @N` | `wt -w 0 close-tab -t <index>` |
| `%window-renamed @N <name>` | `wt -w 0 rename-tab -t <index> "<name>"` |

The daemon maintains an `@windowId → tab index` mapping, updating it on every add/close event to keep indices accurate as tabs shift.

### Known limitations

**`rename-tab -t <index>` briefly steals focus.**
`RenameTabArgs` in Windows Terminal has no index field — it always renames the active tab. Our patch works around this by emitting `SwitchToTab(index)` immediately before `RenameTab`, which causes a brief focus change. This is visible but fast. A proper fix would require adding an index field to `RenameTabArgs` in the WT WinRT interface, which is a more invasive change we've deferred.

**Tab close is one-way.**
When the user closes a Windows Terminal tab directly (rather than through psmux), the psmux session still exists. The daemon has no way to detect WT tab closures — Windows Terminal exposes no event API for this. The user would need to manually close the psmux window (`Ctrl-b x`) to clean up.

**Index drift.**
WT tab indices shift when tabs open or close. The daemon must update its mapping table after every event. Race conditions are possible if the user rapidly opens/closes tabs.

## Sync daemon

`psmux-sync.ps1` connects to psmux in control mode and keeps WT tabs in sync with psmux windows.

### Usage

```powershell
# Basic: assumes WT tabs are already open and in the same order as psmux windows
./psmux-sync.ps1

# Specific session
./psmux-sync.ps1 -Session main

# Create WT tabs for all existing psmux windows on startup
./psmux-sync.ps1 -CreateTabs

# Target a specific WT window (default: 0)
./psmux-sync.ps1 -WtWindow 1
```

The daemon maintains an `@windowId → tab index` map and updates it on every add/close event. It handles the initial name assignment by buffering `%window-add` events until the first `%window-renamed` fires (which psmux sends immediately after creation with the initial window name).

### Startup modes

**Default** (`-CreateTabs` not set): the daemon assumes WT already has tabs open that correspond to the current psmux windows, in the same order. Use this if you opened WT and psmux together and they're already in sync.

**`-CreateTabs`**: on startup, the daemon creates a new WT tab for each existing psmux window. Use this when psmux is already running with sessions you want to mirror into fresh WT tabs.

## Project structure

```
wt-psmux/
  terminal/                               ← microsoft/terminal submodule (unmodified)
  patches/
    0001-add-close-tab-rename-tab-cli.patch  ← the only change to WT source
  psmux-sync.ps1                          ← sync daemon: maps psmux window events to wt commands
  apply-patches.ps1                       ← applies patches, fails loudly if upstream changed
  build.ps1                               ← builds patched binaries locally
  .github/workflows/build.yml             ← CI: verify + build + release on push; weekly patch check
```

The patch is intentionally minimal — 2 new functions in `AppCommandlineArgs.cpp`, 4 new member declarations in `AppCommandlineArgs.h`. No changes to WinRT interfaces, IDL files, settings schema, or any other WT component.

## Building

### Prerequisites

- Visual Studio 2022 with "Desktop development with C++" and "Universal Windows Platform development" workloads
- Windows SDK 10.0.22621 or later
- NuGet CLI

### Steps

```powershell
git clone --recurse-submodules https://github.com/your-username/wt-psmux
cd wt-psmux
./build.ps1
```

Binaries will be at `terminal/bin/x64/Release/WindowsTerminal.exe` and `wt.exe`.

### Installation

Replace the files in your Windows Terminal installation directory (typically `C:\Program Files\WindowsTerminal\`).

> **Note:** Requires admin privileges. Use `gsudo` or run from an elevated prompt.

## CI / keeping up with upstream

GitHub Actions runs on every push and on a weekly schedule. The workflow:

1. Checks out the repo with submodules
2. Runs `apply-patches.ps1` — if the patch no longer applies cleanly, the build fails immediately, which is a signal that upstream WT changed something in `AppCommandlineArgs.cpp`
3. Builds `x64` and `arm64` binaries
4. On `main`, creates a GitHub Release with the binaries

When the weekly run fails on patch application, update the submodule to the new WT commit and rework the patch against the new code.

## Relationship to upstream

This project makes no claim of official affiliation with Microsoft or the Windows Terminal team. The patch is offered as a contribution — see [microsoft/terminal#15747](https://github.com/microsoft/terminal/issues/15747) for the upstream feature request.
