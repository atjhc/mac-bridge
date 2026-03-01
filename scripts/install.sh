#!/bin/bash
set -e

# MacBridge LaunchAgent Installation Script
# Usage: ./scripts/install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCHD_DIR="$PROJECT_DIR/launchd"
TARGET_DIR="$HOME/Library/LaunchAgents"
LABEL="com.user.macbridge"
BINARY="MacBridge"
PORT=7330

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BOLD}MacBridge LaunchAgent Installer${RESET}"
echo "================================"
echo

# Check if binary exists
echo "Checking for release binary..."
if [ ! -f "$PROJECT_DIR/.build/release/$BINARY" ]; then
    echo -e "  ${RED}$BINARY binary not found${RESET}"
    echo "  Run 'swift build -c release' first"
    exit 1
fi
echo -e "${GREEN}Binary found${RESET}"
echo

# Create LaunchAgents directory if needed
mkdir -p "$TARGET_DIR"

PLIST="$LAUNCHD_DIR/$LABEL.plist"
TARGET="$TARGET_DIR/$LABEL.plist"

echo "Installing $LABEL..."

# Unload if already loaded
if launchctl list | grep -q "$LABEL"; then
    echo "  Unloading existing service..."
    launchctl unload "$TARGET" 2>/dev/null || true
fi

# Copy plist, replacing __VARNAME__ placeholders with env vars
echo "  Copying to $TARGET_DIR/"
perl -pe 's/__(\w+)__/$ENV{$1}/g' "$PLIST" > "$TARGET"

# Load and start the service
echo "  Loading service..."
launchctl load "$TARGET"
echo "  Starting service..."
launchctl start "$LABEL"

echo -e "  ${GREEN}$LABEL installed and started${RESET}"
echo

# Verify service is running
echo "Verifying service..."
echo

up=0
for i in $(seq 1 20); do
    if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
        up=1
        break
    fi
    sleep 0.5
done

if [ "$up" -eq 1 ]; then
    echo -e "  ${GREEN}$BINARY running on port $PORT${RESET}"
else
    echo -e "  ${YELLOW}$BINARY may not be running (port $PORT)${RESET}"
fi

echo
echo -e "${BOLD}Logs:${RESET}"
echo "   Startup logs: ~/Library/Logs/macbridge.log (stdout/stderr from launchd)"
echo "   Request logs: log stream --predicate 'subsystem == \"com.user.bridge\"' --level info"
echo
echo -e "${GREEN}Installation complete!${RESET}"
