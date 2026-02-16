#!/bin/bash
set -e

# Swift Bridge LaunchAgent Installation Script
# Installs and loads CalendarBridge, ContactsBridge, and MailBridge LaunchAgents

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCHD_DIR="$PROJECT_DIR/launchd"
TARGET_DIR="$HOME/Library/LaunchAgents"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BOLD}Swift Bridge LaunchAgent Installer${RESET}"
echo "==================================="
echo

# Check if binaries exist
echo "Checking for release binaries..."
if [ ! -f "$PROJECT_DIR/.build/release/CalendarBridge" ]; then
    echo -e "${RED}CalendarBridge binary not found${RESET}"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/.build/release/ContactsBridge" ]; then
    echo -e "${RED}ContactsBridge binary not found${RESET}"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/.build/release/MailBridge" ]; then
    echo -e "${RED}MailBridge binary not found${RESET}"
    echo "   Run 'swift build -c release' first"
    exit 1
fi
echo -e "${GREEN}Binaries found${RESET}"
echo

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Install each plist
for plist in "$LAUNCHD_DIR"/*.plist; do
    filename=$(basename "$plist")
    target="$TARGET_DIR/$filename"
    label=$(basename "$filename" .plist)

    echo "Installing $filename..."

    # Unload if already loaded
    if launchctl list | grep -q "$label"; then
        echo "  Unloading existing service..."
        launchctl unload "$target" 2>/dev/null || true
    fi

    # Copy plist
    echo "  Copying to $TARGET_DIR/"
    cp "$plist" "$target"

    # Load the plist
    echo "  Loading service..."
    launchctl load "$target"

    # Start the service
    echo "  Starting service..."
    launchctl start "$label"

    echo -e "  ${GREEN}$label installed and started${RESET}"
    echo
done

# Wait a moment for services to start
sleep 2

# Verify services are running
echo "Verifying services..."
echo

calendar_status=$(curl -s http://localhost:7334/health 2>/dev/null | grep -o '"calendar-bridge"' || echo "")
contacts_status=$(curl -s http://localhost:7335/health 2>/dev/null | grep -o '"contacts-bridge"' || echo "")
mail_status=$(curl -s http://localhost:7333/health 2>/dev/null | grep -o '"mail-bridge"' || echo "")

if [ -n "$calendar_status" ]; then
    echo -e "  ${GREEN}Calendar Bridge running on port 7334${RESET}"
else
    echo -e "  ${YELLOW}Calendar Bridge may not be running${RESET}"
fi

if [ -n "$contacts_status" ]; then
    echo -e "  ${GREEN}Contacts Bridge running on port 7335${RESET}"
else
    echo -e "  ${YELLOW}Contacts Bridge may not be running${RESET}"
fi

if [ -n "$mail_status" ]; then
    echo -e "  ${GREEN}Mail Bridge running on port 7333${RESET}"
else
    echo -e "  ${YELLOW}Mail Bridge may not be running${RESET}"
fi

echo
echo -e "${BOLD}Logs:${RESET}"
echo "   Startup logs: ~/Library/Logs/*-bridge.log (stdout/stderr from launchd)"
echo "   Request logs: log stream --predicate 'subsystem == \"com.user.bridge\"' --level info"
echo
echo -e "${GREEN}Installation complete!${RESET}"
