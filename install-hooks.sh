#!/bin/bash
# Install Claude Code status hooks
# This script installs the status-hook.sh to ~/.claude/hooks/ and configures hooks in settings.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
HOOK_SCRIPT="$HOOKS_DIR/status-hook.sh"

echo "Installing Claude Code status hooks..."

# Create directories if they don't exist
mkdir -p "$HOOKS_DIR"

# Copy hook script
cp "$SCRIPT_DIR/hooks/status-hook.sh" "$HOOK_SCRIPT"
chmod +x "$HOOK_SCRIPT"
echo "✓ Installed hook script to $HOOK_SCRIPT"

# Initialize settings file if it doesn't exist
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
    echo "✓ Created $SETTINGS_FILE"
fi

# Define the hooks configuration we want to add
HOOKS_CONFIG=$(cat << 'EOF'
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/status-hook.sh" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/status-hook.sh" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/status-hook.sh" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/status-hook.sh" }] }]
  }
}
EOF
)

# Merge hooks into existing settings
# This preserves existing settings and merges the hooks section
CURRENT_SETTINGS=$(cat "$SETTINGS_FILE")

# Check if settings already has hooks
if echo "$CURRENT_SETTINGS" | /usr/bin/jq -e '.hooks' > /dev/null 2>&1; then
    # Merge our hooks with existing hooks
    MERGED=$(/usr/bin/jq -s '
        .[0] as $current |
        .[1] as $new |
        $current * {
            hooks: (
                ($current.hooks // {}) * $new.hooks
            )
        }
    ' <(echo "$CURRENT_SETTINGS") <(echo "$HOOKS_CONFIG"))
else
    # No existing hooks, just merge at top level
    MERGED=$(/usr/bin/jq -s '.[0] * .[1]' <(echo "$CURRENT_SETTINGS") <(echo "$HOOKS_CONFIG"))
fi

# Write merged settings back
echo "$MERGED" > "$SETTINGS_FILE"
echo "✓ Updated hooks in $SETTINGS_FILE"

# Initialize empty status file
STATUS_FILE="$CLAUDE_DIR/instance-status.json"
if [ ! -f "$STATUS_FILE" ]; then
    echo '{"instances":{}}' > "$STATUS_FILE"
    echo "✓ Created $STATUS_FILE"
fi

echo ""
echo "Installation complete!"
echo ""
echo "The following hooks are now active:"
echo "  - SessionStart: Tracks new Claude Code instances"
echo "  - UserPromptSubmit: Marks instance as 'working'"
echo "  - Stop: Marks instance as 'waiting'"
echo "  - SessionEnd: Removes instance from tracking"
echo ""
echo "Status is written to: $STATUS_FILE"
echo ""
echo "To uninstall, remove the hooks from $SETTINGS_FILE"
