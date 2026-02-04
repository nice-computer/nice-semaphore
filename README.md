# NiceToast

A macOS menu bar app that monitors running Claude Code CLI instances and displays their status.

## Features

- **Status indicators** - Colored boxes show each instance's state at a glance
- **Space numbers** - Shows which macOS Space each instance is on
- **Focus detection** - Highlights the currently focused instance (rounded square vs circle)
- **Real-time updates** - Status changes appear immediately via Claude Code hooks

## Status Colors

| Status | Color | Meaning |
|--------|-------|---------|
| Working | Orange | Claude is processing/using tools |
| Waiting | Yellow | Claude needs your input (question or permission prompt) |
| Idle | Green | Turn complete, ready for next prompt |

## How It Works

NiceToast uses Claude Code hooks to track instance status:

| Hook | Triggers |
|------|----------|
| `SessionStart` | New instance detected, set to idle |
| `UserPromptSubmit` | User sent a message, set to working |
| `PreToolUse` | Detects AskUserQuestion/ExitPlanMode, set to waiting |
| `PostToolUse` | Tool completed, ensures working state |
| `Notification` | Permission prompt shown, set to waiting |
| `Stop` | Claude's turn ended, set to idle |
| `SessionEnd` | Instance closed, removed from tracking |

The menu bar shows colored boxes with Space numbers. Click to see the full list with project paths.

## Requirements

- macOS 13+
- Claude Code CLI
- iTerm2 (for focus detection)
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
    "PreToolUse": [...],
    "PostToolUse": [...],
    "Notification": [...],
    "Stop": [...],
    "SessionEnd": [...]
  }
}
```

Optionally delete:
- `~/.claude/hooks/nice-toast-status.sh`
- `~/.claude/nice-toast-status.json`

## Inspiration

Visual design inspired by [SpaceId](https://github.com/dshnkao/SpaceId/) - a macOS menu bar app that shows the current Space number.
