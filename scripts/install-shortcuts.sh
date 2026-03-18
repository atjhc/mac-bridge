#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SHORTCUTS_DIR="$PROJECT_DIR/shortcuts"

# Generate shortcuts if not already present (skip _unsigned temp files)
SIGNED_COUNT=$(ls "$SHORTCUTS_DIR"/MacBridge*.shortcut 2>/dev/null | grep -v _unsigned | wc -l | tr -d ' ')
if [ ! -d "$SHORTCUTS_DIR" ] || [ "$SIGNED_COUNT" -eq 0 ]; then
    echo "Generating shortcut files..."
    python3 "$SCRIPT_DIR/generate-shortcuts.py"
fi

# Get list of installed shortcuts
INSTALLED=$(shortcuts list 2>/dev/null)

NEEDED=0
SKIPPED=0
INSTALLED_COUNT=0

for f in "$SHORTCUTS_DIR"/MacBridge*.shortcut; do
    [ -f "$f" ] || continue
    [[ "$f" == *_unsigned* ]] && continue
    NAME=$(basename "$f" .shortcut)

    if echo "$INSTALLED" | grep -qF "$NAME"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    NEEDED=$((NEEDED + 1))
done

if [ "$NEEDED" -eq 0 ]; then
    echo "All shortcuts already installed ($SKIPPED skipped)."
    exit 0
fi

echo ""
echo "Installing $NEEDED MacBridge shortcuts for Notes."
echo "Each will open a dialog — click 'Add Shortcut' for each one."
echo ""
read -p "Press Enter to begin..."

for f in "$SHORTCUTS_DIR"/MacBridge*.shortcut; do
    [ -f "$f" ] || continue
    [[ "$f" == *_unsigned* ]] && continue
    NAME=$(basename "$f" .shortcut)

    if echo "$INSTALLED" | grep -qF "$NAME"; then
        continue
    fi

    echo "  → $NAME"
    open "$f"
    sleep 1

    # Wait for user to accept
    while true; do
        CURRENT=$(shortcuts list 2>/dev/null)
        if echo "$CURRENT" | grep -qF "$NAME"; then
            INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
            break
        fi
        sleep 1
    done
done

echo ""
echo "Installed $INSTALLED_COUNT shortcuts, $SKIPPED already present."
echo ""
echo "Warming up permissions..."
echo "macOS will prompt you to allow Shortcuts to access Notes."
echo "Choose 'Always Allow' for each prompt."
echo ""

# Run each shortcut once with dummy input to trigger permission dialogs.
# The shortcuts gracefully no-op when the target note doesn't exist.
WARMUP_SHORTCUTS=(
    "MacBridge - Notes Create Markdown"
    "MacBridge - Notes Add Checklist Item"
    "MacBridge - Notes Append Markdown"
    "MacBridge - Notes Add Table"
    "MacBridge - Notes Pin"
    "MacBridge - Notes Unpin"
)

for NAME in "${WARMUP_SHORTCUTS[@]}"; do
    if ! shortcuts list 2>/dev/null | grep -qF "$NAME"; then
        continue
    fi
    echo "  Warming up: $NAME"
    osascript -e "tell application \"Shortcuts Events\" to run shortcut \"$NAME\" with input \"{\\\"noteName\\\":\\\"__macbridge_warmup__\\\",\\\"name\\\":\\\"__warmup__\\\",\\\"text\\\":\\\"__warmup__\\\",\\\"content\\\":\\\"__warmup__\\\",\\\"markdown\\\":\\\"__warmup__\\\",\\\"tags\\\":\\\"__warmup__\\\",\\\"csv\\\":\\\"a\\\"}\"" 2>/dev/null || true
done

echo ""
echo "Done. All shortcuts installed and permissions granted."
echo "You can verify with: curl -s -X POST http://localhost:7330/notes/checklist -H 'Content-Type: application/json' -d '{\"noteName\":\"Any Note\",\"text\":\"Test\"}'"
