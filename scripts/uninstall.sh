#!/bin/bash
set -e

# MacBridge LaunchAgent Uninstallation Script
# Usage: ./scripts/uninstall.sh

TARGET_DIR="$HOME/Library/LaunchAgents"
LABEL="com.user.macbridge"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BOLD}MacBridge LaunchAgent Uninstaller${RESET}"
echo "=================================="
echo

PLIST="$TARGET_DIR/$LABEL.plist"

if [ -f "$PLIST" ]; then
    echo "Removing $LABEL..."

    echo "  Stopping service..."
    launchctl stop "$LABEL" 2>/dev/null || true

    echo "  Unloading service..."
    launchctl unload "$PLIST" 2>/dev/null || true

    echo "  Removing plist..."
    rm "$PLIST"

    echo -e "  ${GREEN}$LABEL removed${RESET}"
    echo
else
    echo -e "  ${YELLOW}$LABEL not found (already removed?)${RESET}"
    echo
fi

echo -e "${GREEN}Uninstallation complete!${RESET}"
echo
echo "Note: Binaries in .build/release/ were not removed"
echo "      Logs in ~/Library/Logs/ were not removed"
