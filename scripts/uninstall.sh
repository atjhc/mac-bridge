#!/bin/bash
set -e

# Swift Bridge LaunchAgent Uninstallation Script
# Stops and unloads CalendarBridge, ContactsBridge, and MailBridge LaunchAgents

TARGET_DIR="$HOME/Library/LaunchAgents"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BOLD}Swift Bridge LaunchAgent Uninstaller${RESET}"
echo "====================================="
echo

services=(
    "com.user.calendar-bridge-swift"
    "com.user.contacts-bridge-swift"
    "com.user.mail-bridge-swift"
)

for label in "${services[@]}"; do
    plist="$TARGET_DIR/$label.plist"

    if [ -f "$plist" ]; then
        echo "Removing $label..."

        # Stop the service
        echo "  Stopping service..."
        launchctl stop "$label" 2>/dev/null || true

        # Unload the plist
        echo "  Unloading service..."
        launchctl unload "$plist" 2>/dev/null || true

        # Remove the plist
        echo "  Removing plist..."
        rm "$plist"

        echo -e "  ${GREEN}$label removed${RESET}"
        echo
    else
        echo -e "  ${YELLOW}$label not found (already removed?)${RESET}"
        echo
    fi
done

echo -e "${GREEN}Uninstallation complete!${RESET}"
echo
echo "Note: Binaries in .build/release/ were not removed"
echo "      Logs in ~/Library/Logs/ were not removed"
