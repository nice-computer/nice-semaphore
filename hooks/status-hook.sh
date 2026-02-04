#!/bin/bash
# Claude Code Status Hook
# Reads hook input from stdin, updates ~/.claude/instance-status.json

STATUS_FILE="$HOME/.claude/instance-status.json"
LOCK_FILE="$HOME/.claude/instance-status.lock"

# Read JSON input from stdin
INPUT=$(cat)

# Parse fields from input
SESSION_ID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | /usr/bin/jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | /usr/bin/jq -r '.hook_event_name // empty')

# Exit if we don't have required fields
if [ -z "$SESSION_ID" ] || [ -z "$EVENT" ]; then
    exit 0
fi

# Get current timestamp in ISO 8601 format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get terminal app PID (great-grandparent: hook -> claude -> shell -> terminal app)
SHELL_PID=$(ps -o ppid= -p "$PPID" | tr -d ' ')
TERMINAL_PID=$(ps -o ppid= -p "$SHELL_PID" 2>/dev/null | tr -d ' ')

# Get the TTY for foreground detection
TTY_PATH=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
if [ -n "$TTY_PATH" ] && [ "$TTY_PATH" != "??" ]; then
    TTY_PATH="/dev/$TTY_PATH"
else
    TTY_PATH=""
fi

# Function to safely update the status file with locking
update_status_file() {
    local action="$1"
    local status="$2"

    # Create lock directory for atomic locking (mkdir is atomic)
    while ! mkdir "$LOCK_FILE" 2>/dev/null; do
        sleep 0.01
    done

    # Ensure lock is released on exit
    trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT

    # Initialize file if it doesn't exist or is empty
    if [ ! -f "$STATUS_FILE" ] || [ ! -s "$STATUS_FILE" ]; then
        echo '{"instances":{}}' > "$STATUS_FILE"
    fi

    case "$action" in
        add)
            # Add new instance with PID, terminal PID, and TTY (first remove any old entries with same PID)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg status "$status" \
               --arg project "$CWD" \
               --arg ts "$TIMESTAMP" \
               --argjson pid "$PPID" \
               --argjson termPid "${TERMINAL_PID:-0}" \
               --arg tty "$TTY_PATH" \
               '.instances |= with_entries(select(.value.pid != $pid)) | .instances[$sid] = {status: $status, project: $project, lastUpdate: $ts, pid: $pid, terminalPid: $termPid, tty: $tty}' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
        update)
            # Update instance status (preserve existing PID)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg status "$status" \
               --arg project "$CWD" \
               --arg ts "$TIMESTAMP" \
               '.instances[$sid].status = $status | .instances[$sid].project = $project | .instances[$sid].lastUpdate = $ts' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
        remove)
            # Remove instance
            /usr/bin/jq --arg sid "$SESSION_ID" \
               'del(.instances[$sid])' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
    esac

    # Release lock
    rmdir "$LOCK_FILE" 2>/dev/null
    trap - EXIT
}

# Handle different hook events
case "$EVENT" in
    SessionStart)
        update_status_file "add" "waiting"
        ;;
    UserPromptSubmit)
        update_status_file "update" "working"
        ;;
    Stop)
        update_status_file "update" "waiting"
        ;;
    SessionEnd)
        update_status_file "remove" ""
        ;;
esac

exit 0
