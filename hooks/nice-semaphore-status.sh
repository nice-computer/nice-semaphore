#!/bin/bash
# Claude Code Status Hook
# Reads hook input from stdin, updates ~/.claude/instance-status.json

# Paths can be overridden via env vars for testing
STATUS_FILE="${NICE_SEMAPHORE_STATUS_FILE:-$HOME/.claude/nice-semaphore-status.json}"
LOCK_FILE="${NICE_SEMAPHORE_LOCK_FILE:-$HOME/.claude/nice-semaphore-status.lock}"
LOG_FILE="${NICE_SEMAPHORE_LOG_FILE:-/tmp/nice-semaphore.log}"

log() {
    local project="${CWD##*/}"
    [ -n "$NICE_SEMAPHORE_DEBUG" ] && echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [$project] $1" >> "$LOG_FILE"
}

# Read JSON input from stdin
INPUT=$(cat)

# Parse fields from input
SESSION_ID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | /usr/bin/jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | /usr/bin/jq -r '.hook_event_name // empty')
TOOL_NAME=$(echo "$INPUT" | /usr/bin/jq -r '.tool_name // empty')

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

# Map a status to an iTerm2 tab color and write it to this instance's TTY.
# Colors match the menu bar indicators (see README status table).
set_tab_color() {
    local status="$1"
    local rgb seq

    [ "${NICE_SEMAPHORE_TAB_COLORS:-1}" = "0" ] && return 0

    # Tests can redirect the escape sequences to a regular file
    local target="${NICE_SEMAPHORE_TTY_OVERRIDE:-$TTY_PATH}"
    [ -z "$target" ] && return 0
    [ -w "$target" ] || return 0

    case "$status" in
        working) rgb="255 149 0" ;;   # orange
        waiting) rgb="255 59 48" ;;   # red
        idle)    rgb="52 199 89" ;;   # green
        default) rgb="" ;;
        *)       return 0 ;;
    esac

    if [ -z "$rgb" ]; then
        seq=$'\033]6;1;bg;*;default\a'
    else
        # shellcheck disable=SC2086
        set -- $rgb
        seq=$(printf '\033]6;1;bg;red;brightness;%d\a\033]6;1;bg;green;brightness;%d\a\033]6;1;bg;blue;brightness;%d\a' "$1" "$2" "$3")
    fi

    # Inside tmux the sequence must be wrapped for passthrough to the outer terminal,
    # with every ESC doubled. Note $esc is a literal ESC byte: sed patterns do not
    # understand \033, so the escape has to be substituted in by the shell first.
    if [ -n "$TMUX" ]; then
        local esc=$'\033'
        seq=$'\033Ptmux;'$(printf '%s' "$seq" | sed "s/$esc/$esc$esc/g")$'\033\\'
    fi

    printf '%s' "$seq" > "$target" 2>/dev/null || true
}

# Re-read the status this instance actually ended up in and color the tab to match.
# Reading back (rather than trusting the requested status) keeps the tab honest when
# a jq update was a no-op because the instance did not exist.
sync_tab_color() {
    local current
    current=$(/usr/bin/jq -r --arg sid "$SESSION_ID" '.instances[$sid].status // empty' "$STATUS_FILE" 2>/dev/null)
    [ -n "$current" ] && set_tab_color "$current"
}

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
        set_pending)
            # Set pendingQuestion flag and status to waiting immediately (only if instance exists)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg ts "$TIMESTAMP" \
               'if (.instances | has($sid)) then .instances[$sid].pendingQuestion = true | .instances[$sid].status = "waiting" | .instances[$sid].lastUpdate = $ts else . end' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
        clear_pending)
            # Clear pendingQuestion flag and update status (only if instance exists)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg status "$status" \
               --arg ts "$TIMESTAMP" \
               'if (.instances | has($sid)) then .instances[$sid].pendingQuestion = false | .instances[$sid].status = $status | .instances[$sid].lastUpdate = $ts else . end' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
        stop_check)
            # On Stop: turn is complete, always go to idle (only if instance exists)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg ts "$TIMESTAMP" \
               'if (.instances | has($sid)) then .instances[$sid].status = "idle" | .instances[$sid].lastUpdate = $ts | .instances[$sid].pendingQuestion = false else . end' \
               "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            ;;
        ensure_working)
            # If status is idle or waiting (permission prompt answered), change to working (only if instance exists)
            /usr/bin/jq --arg sid "$SESSION_ID" \
               --arg ts "$TIMESTAMP" \
               'if ((.instances | has($sid)) and (.instances[$sid].status == "idle" or .instances[$sid].status == "waiting")) then .instances[$sid].status = "working" | .instances[$sid].lastUpdate = $ts | .instances[$sid].pendingQuestion = false else . end' \
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

    # Reflect the new state in the iTerm2 tab color
    if [ "$action" = "remove" ]; then
        set_tab_color "default"
    else
        sync_tab_color
    fi
}

# Handle different hook events
log "EVENT=$EVENT TOOL_NAME=$TOOL_NAME SESSION_ID=$SESSION_ID"
case "$EVENT" in
    SessionStart)
        log "→ add idle"
        update_status_file "add" "idle"
        ;;
    UserPromptSubmit)
        log "→ clear_pending working"
        update_status_file "clear_pending" "working"
        ;;
    PreToolUse)
        # Set waiting BEFORE AskUserQuestion/ExitPlanMode runs (so user sees red while question is displayed)
        log "→ PreToolUse tool=$TOOL_NAME"
        case "$TOOL_NAME" in
            AskUserQuestion|ExitPlanMode)
                log "→ set_pending (question tool - pre)"
                update_status_file "set_pending" ""
                ;;
        esac
        ;;
    PostToolUse)
        # After any tool, ensure we're showing as working
        log "→ PostToolUse tool=$TOOL_NAME"
        case "$TOOL_NAME" in
            AskUserQuestion|ExitPlanMode)
                # Question was just answered, clear pending and set working
                log "→ clear_pending working (after question)"
                update_status_file "clear_pending" "working"
                ;;
            *)
                # Any other tool means we're working - this catches resumed sessions
                log "→ ensure_working"
                update_status_file "ensure_working" ""
                ;;
        esac
        ;;
    Notification)
        # Permission prompt notification - user needs to approve/deny
        log "→ Notification (permission prompt)"
        update_status_file "set_pending" ""
        ;;
    Stop)
        log "→ stop → idle"
        update_status_file "stop_check" ""
        ;;
    SessionEnd)
        log "→ remove"
        update_status_file "remove" ""
        ;;
esac

exit 0
