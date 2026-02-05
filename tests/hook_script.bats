#!/usr/bin/env bats

# Test suite for nice-semaphore-status.sh hook script

setup() {
    # Create temp directory for test isolation
    export TEST_DIR="$(mktemp -d)"
    export NICE_SEMAPHORE_STATUS_FILE="$TEST_DIR/status.json"
    export NICE_SEMAPHORE_LOCK_FILE="$TEST_DIR/status.lock"
    export NICE_SEMAPHORE_LOG_FILE="$TEST_DIR/hook.log"

    # Initialize empty status file
    echo '{"instances":{}}' > "$NICE_SEMAPHORE_STATUS_FILE"

    # Path to hook script
    export HOOK_SCRIPT="$BATS_TEST_DIRNAME/../hooks/nice-semaphore-status.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper to run hook with JSON input
run_hook() {
    echo "$1" | "$HOOK_SCRIPT"
}

# Helper to get status for a session
get_status() {
    jq -r ".instances[\"$1\"].status // empty" "$NICE_SEMAPHORE_STATUS_FILE"
}

# Helper to check if session exists
session_exists() {
    jq -e ".instances[\"$1\"]" "$NICE_SEMAPHORE_STATUS_FILE" > /dev/null 2>&1
}

# =============================================================================
# SessionStart tests
# =============================================================================

@test "SessionStart: creates new instance with idle status" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'

    [ "$(get_status test-session)" = "idle" ]
}

@test "SessionStart: stores project path" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/my-project","hook_event_name":"SessionStart"}'

    run jq -r '.instances["test-session"].project' "$NICE_SEMAPHORE_STATUS_FILE"
    [ "$output" = "/tmp/my-project" ]
}

# =============================================================================
# UserPromptSubmit tests
# =============================================================================

@test "UserPromptSubmit: sets status to working" {
    # Setup: create an idle session
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    [ "$(get_status test-session)" = "idle" ]

    # Action: submit a prompt
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'

    # Assert: status is now working
    [ "$(get_status test-session)" = "working" ]
}

@test "UserPromptSubmit: clears pendingQuestion flag" {
    # Setup: create a session with pending question
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'

    # Verify pending is set
    run jq -r '.instances["test-session"].pendingQuestion' "$NICE_SEMAPHORE_STATUS_FILE"
    [ "$output" = "true" ]

    # Action: submit a prompt
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'

    # Assert: pendingQuestion is cleared
    run jq -r '.instances["test-session"].pendingQuestion' "$NICE_SEMAPHORE_STATUS_FILE"
    [ "$output" = "false" ]
}

# =============================================================================
# PreToolUse tests
# =============================================================================

@test "PreToolUse: AskUserQuestion sets status to waiting" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status test-session)" = "working" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'

    [ "$(get_status test-session)" = "waiting" ]
}

@test "PreToolUse: ExitPlanMode sets status to waiting" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}'

    [ "$(get_status test-session)" = "waiting" ]
}

@test "PreToolUse: other tools do not change status" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status test-session)" = "working" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"Edit"}'

    [ "$(get_status test-session)" = "working" ]
}

# =============================================================================
# PostToolUse tests
# =============================================================================

@test "PostToolUse: AskUserQuestion sets status to working (question answered)" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
    [ "$(get_status test-session)" = "waiting" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'

    [ "$(get_status test-session)" = "working" ]
}

@test "PostToolUse: other tools ensure working state from idle" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    [ "$(get_status test-session)" = "idle" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"Read"}'

    [ "$(get_status test-session)" = "working" ]
}

# =============================================================================
# Notification tests
# =============================================================================

@test "Notification: permission prompt sets status to waiting" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status test-session)" = "working" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"Notification"}'

    [ "$(get_status test-session)" = "waiting" ]
}

# =============================================================================
# Stop tests
# =============================================================================

@test "Stop: sets status to idle" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status test-session)" = "working" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"Stop"}'

    [ "$(get_status test-session)" = "idle" ]
}

@test "Stop: clears pendingQuestion flag" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'

    run jq -r '.instances["test-session"].pendingQuestion' "$NICE_SEMAPHORE_STATUS_FILE"
    [ "$output" = "true" ]

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"Stop"}'

    run jq -r '.instances["test-session"].pendingQuestion' "$NICE_SEMAPHORE_STATUS_FILE"
    [ "$output" = "false" ]
}

# =============================================================================
# SessionEnd tests
# =============================================================================

@test "SessionEnd: removes instance" {
    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    session_exists "test-session"

    run_hook '{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"SessionEnd"}'

    ! session_exists "test-session"
}

# =============================================================================
# Scenario tests
# =============================================================================

@test "Scenario: typical session lifecycle" {
    # Start session
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    [ "$(get_status s1)" = "idle" ]

    # User submits prompt
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status s1)" = "working" ]

    # Claude uses some tools
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"Read"}'
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"Read"}'
    [ "$(get_status s1)" = "working" ]

    # Claude finishes
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Stop"}'
    [ "$(get_status s1)" = "idle" ]

    # Session ends
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionEnd"}'
    ! session_exists "s1"
}

@test "Scenario: permission prompt accepted" {
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status s1)" = "working" ]

    # Permission prompt appears
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Notification"}'
    [ "$(get_status s1)" = "waiting" ]

    # User accepts, tool runs
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"Bash"}'
    [ "$(get_status s1)" = "working" ]

    # Claude finishes
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Stop"}'
    [ "$(get_status s1)" = "idle" ]
}

@test "Scenario: AskUserQuestion flow" {
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
    [ "$(get_status s1)" = "working" ]

    # Claude asks a question
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
    [ "$(get_status s1)" = "waiting" ]

    # User answers
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
    [ "$(get_status s1)" = "working" ]

    # Claude finishes
    run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Stop"}'
    [ "$(get_status s1)" = "idle" ]
}

# Note: This test cannot run in the current setup because the hook script
# deduplicates sessions by PID (to clean up stale sessions). In tests, all
# simulated sessions share the test process PID, so SessionStart for s2
# removes s1. In production, each Claude instance has a unique PID.
#
# @test "Scenario: multiple concurrent sessions" {
#     run_hook '{"session_id":"s1","cwd":"/tmp/project1","hook_event_name":"SessionStart"}'
#     run_hook '{"session_id":"s2","cwd":"/tmp/project2","hook_event_name":"SessionStart"}'
#     [ "$(get_status s1)" = "idle" ]
#     [ "$(get_status s2)" = "idle" ]
#     ...
# }

# =============================================================================
# Known issues / Expected failures
# =============================================================================

# This test documents the known bug where escaping a permission prompt
# does not fire a Stop hook, leaving the status stuck at "waiting"
#
# @test "Scenario: permission prompt escaped (KNOWN BUG)" {
#     run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
#     run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
#     run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Notification"}'
#     [ "$(get_status s1)" = "waiting" ]
#
#     # User presses Escape - no hook fires!
#     # Expected: status should be "idle"
#     # Actual: status remains "waiting"
#
#     # This test would need a Stop event that Claude Code doesn't send
#     run_hook '{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"Stop"}'
#     [ "$(get_status s1)" = "idle" ]
# }
