#!/bin/bash
# Nice Semaphore session tracker hook
#
# Reads a Claude Code hook event from stdin and maintains:
#   $NICE_SEMAPHORE_HOME/sessions/state.json  current sessions (snapshot)
#   $NICE_SEMAPHORE_HOME/sessions/log.jsonl   append-only session event log
#
# NICE_SEMAPHORE_HOME defaults to ~/Library/Application Support/NiceSemaphore.

ROOT="${NICE_SEMAPHORE_HOME:-$HOME/Library/Application Support/NiceSemaphore}"
SESSIONS_DIR="$ROOT/sessions"
STATE_FILE="$SESSIONS_DIR/state.json"
EVENT_LOG="$SESSIONS_DIR/log.jsonl"
LOCK_DIR="$SESSIONS_DIR/.lock"
DEBUG_LOG="$ROOT/debug.log"
LOG_MAX_BYTES="${NICE_SEMAPHORE_LOG_MAX_BYTES:-10485760}"
JQ=/usr/bin/jq

debug() {
    [ -n "$NICE_SEMAPHORE_DEBUG" ] && echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [${CWD##*/}] $1" >> "$DEBUG_LOG"
}

# Read JSON input from stdin and parse all fields in one jq call
INPUT=$(cat)
SESSION_ID="" CWD="" EVENT="" TOOL_NAME=""
eval "$(echo "$INPUT" | $JQ -r '@sh "SESSION_ID=\(.session_id // "") CWD=\(.cwd // "") EVENT=\(.hook_event_name // "") TOOL_NAME=\(.tool_name // "")"' 2>/dev/null)"

# Exit if we don't have required fields
if [ -z "$SESSION_ID" ] || [ -z "$EVENT" ]; then
    exit 0
fi

mkdir -p "$SESSIONS_DIR"

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

# Atomic lock via mkdir. Shared with the menu bar app, which also writes
# state.json and log.jsonl when it reaps sessions whose process died.
acquire_lock() {
    local tries=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 500 ]; then
            # ~5s without progress: assume a writer was killed while holding the lock
            rmdir "$LOCK_DIR" 2>/dev/null
            tries=0
        fi
        sleep 0.01
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
    trap - EXIT
}

rotate_log_if_needed() {
    [ -f "$EVENT_LOG" ] || return
    local size
    size=$(wc -c < "$EVENT_LOG" | tr -d ' ')
    if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
        mv "$EVENT_LOG" "$SESSIONS_DIR/log-$(date -u +"%Y%m%dT%H%M%SZ").jsonl"
    fi
}

# Append one record to the session event log: append_event <status> <prevStatus>
append_event() {
    rotate_log_if_needed
    $JQ -nc \
        --arg ts "$TIMESTAMP" \
        --arg sid "$SESSION_ID" \
        --arg event "$EVENT" \
        --arg status "$1" \
        --arg prev "$2" \
        --arg cwd "$CWD" \
        --argjson pid "$PPID" \
        --arg tty "$TTY_PATH" \
        --arg tool "$TOOL_NAME" \
        'def nullable: if . == "" then null else . end;
         {v: 1, ts: $ts, sessionId: $sid, event: $event,
          status: ($status | nullable), prevStatus: ($prev | nullable),
          cwd: $cwd, pid: $pid, tty: ($tty | nullable)}
         + (if $tool == "" then {} else {tool: $tool} end)' \
        >> "$EVENT_LOG"
}

# Creates the session if it isn't tracked yet (e.g. the state file was reset
# while the session was running), dropping stale entries that share its PID.
UPSERT='if (.sessions | has($sid)) then . else
    (.sessions |= with_entries(select(.value.pid != $pid)))
    | .sessions[$sid] = {status: "idle", project: $project, lastUpdate: $ts, pid: $pid, terminalPid: $termPid, tty: $tty, pendingQuestion: false}
  end'

# Apply an action to the state file and log the event: update_state <action> [status]
update_state() {
    local action="$1"
    local status="$2"
    local filter

    case "$action" in
        add)
            filter='(.sessions |= with_entries(select(.value.pid != $pid)))
                | .sessions[$sid] = {status: $status, project: $project, lastUpdate: $ts, pid: $pid, terminalPid: $termPid, tty: $tty, pendingQuestion: false}'
            ;;
        set_pending)
            filter="$UPSERT"' | .sessions[$sid] |= (.pendingQuestion = true | .status = "waiting" | .lastUpdate = $ts)'
            ;;
        clear_pending)
            filter="$UPSERT"' | .sessions[$sid] |= (.pendingQuestion = false | .status = $status | .lastUpdate = $ts)'
            ;;
        stop_check)
            filter="$UPSERT"' | .sessions[$sid] |= (.status = "idle" | .lastUpdate = $ts | .pendingQuestion = false)'
            ;;
        ensure_working)
            filter="$UPSERT"' | .sessions[$sid] |= (if (.status == "idle" or .status == "waiting") then .status = "working" | .lastUpdate = $ts | .pendingQuestion = false else . end)'
            ;;
        remove)
            filter='del(.sessions[$sid])'
            ;;
        *)
            return
            ;;
    esac

    acquire_lock

    # Read the previous status; (re)initialize a missing, empty or corrupt state file
    local prev_status
    if ! prev_status=$($JQ -er --arg sid "$SESSION_ID" '.sessions | if type == "object" then (.[$sid].status // "") else error end' "$STATE_FILE" 2>/dev/null); then
        echo '{"v":1,"sessions":{}}' > "$STATE_FILE"
        prev_status=""
    fi

    $JQ --arg sid "$SESSION_ID" \
        --arg status "$status" \
        --arg project "$CWD" \
        --arg ts "$TIMESTAMP" \
        --argjson pid "$PPID" \
        --argjson termPid "${TERMINAL_PID:-0}" \
        --arg tty "$TTY_PATH" \
        "$filter" \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    local new_status
    new_status=$($JQ -r --arg sid "$SESSION_ID" '.sessions[$sid].status // ""' "$STATE_FILE")

    # Lifecycle events are always logged; everything else only when the status changed
    case "$EVENT" in
        SessionStart|SessionEnd|UserPromptSubmit)
            append_event "$new_status" "$prev_status"
            ;;
        *)
            [ "$new_status" != "$prev_status" ] && append_event "$new_status" "$prev_status"
            ;;
    esac

    release_lock
}

# Handle different hook events
debug "EVENT=$EVENT TOOL_NAME=$TOOL_NAME SESSION_ID=$SESSION_ID"
case "$EVENT" in
    SessionStart)
        debug "→ add idle"
        update_state "add" "idle"
        ;;
    UserPromptSubmit)
        debug "→ clear_pending working"
        update_state "clear_pending" "working"
        ;;
    PreToolUse)
        # Set waiting BEFORE AskUserQuestion/ExitPlanMode runs (so user sees red while question is displayed)
        case "$TOOL_NAME" in
            AskUserQuestion|ExitPlanMode)
                debug "→ set_pending (question tool - pre)"
                update_state "set_pending"
                ;;
        esac
        ;;
    PostToolUse)
        case "$TOOL_NAME" in
            AskUserQuestion|ExitPlanMode)
                # Question was just answered, clear pending and set working
                debug "→ clear_pending working (after question)"
                update_state "clear_pending" "working"
                ;;
            *)
                # Any other tool means we're working - this catches resumed sessions
                debug "→ ensure_working"
                update_state "ensure_working"
                ;;
        esac
        ;;
    Notification)
        # Permission prompt notification - user needs to approve/deny
        debug "→ set_pending (permission prompt)"
        update_state "set_pending"
        ;;
    Stop)
        debug "→ stop → idle"
        update_state "stop_check"
        ;;
    SessionEnd)
        debug "→ remove"
        update_state "remove"
        ;;
esac

exit 0
