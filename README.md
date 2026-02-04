# NiceToast

A macOS menu bar app that displays colored dots representing running Claude Code instances and their status.

## How It Works

NiceToast uses Claude Code hooks to track instance status:

| Event | Status | Color |
|-------|--------|-------|
| Session starts | Waiting | Green |
| User submits prompt | Working | Orange |
| Claude finishes | Waiting | Green |
| Session ends | (removed) | - |

The menu bar shows colored dots for each active instance. Click to see the full list with project paths.

## Requirements

- macOS 13+
- Claude Code CLI
- `jq` (usually pre-installed on macOS)

## Installation

### 1. Install the hooks

```bash
./install-hooks.sh
```

This installs a hook script to `~/.claude/hooks/` and configures Claude Code to call it on session events. Your existing `~/.claude/settings.json` is backed up before modification.

### 2. Build and run

```bash
swift build
swift run
```

Or open in Xcode:

```bash
open Package.swift
```

### Build for distribution

```bash
swift build -c release
# Binary at .build/release/NiceToast
```

## Uninstall

Remove the hooks from `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [...],
    "UserPromptSubmit": [...],
    "Stop": [...],
    "SessionEnd": [...]
  }
}
```

Optionally delete:
- `~/.claude/hooks/status-hook.sh`
- `~/.claude/instance-status.json`
