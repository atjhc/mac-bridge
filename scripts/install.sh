#!/bin/bash
set -e

# Swift Bridge LaunchAgent Installation Script
# Usage: ./scripts/install.sh [bridge...]
# Examples:
#   ./scripts/install.sh                # install all
#   ./scripts/install.sh calendar       # install one
#   ./scripts/install.sh mail contacts  # install specific ones

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCHD_DIR="$PROJECT_DIR/launchd"
TARGET_DIR="$HOME/Library/LaunchAgents"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# Map short names to launchd labels, binary names, and health ports
resolve() {
    local label binary port
    case "$1" in
        calendar) label="com.user.calendar-bridge-swift" binary="CalendarBridge" port=7334 ;;
        contacts) label="com.user.contacts-bridge-swift" binary="ContactsBridge" port=7335 ;;
        mail)     label="com.user.mail-bridge-swift"     binary="MailBridge"     port=7333 ;;
        *) echo -e "${RED}Unknown bridge: $1${RESET}" >&2; return 1 ;;
    esac
    echo "$label $binary $port"
}

# Build list of bridges to install
if [ $# -gt 0 ]; then
    bridges=("$@")
else
    bridges=(calendar contacts mail)
fi

echo -e "${BOLD}Swift Bridge LaunchAgent Installer${RESET}"
echo "==================================="
echo

# Check if requested binaries exist
echo "Checking for release binaries..."
missing=0
for name in "${bridges[@]}"; do
    read -r label binary port <<< "$(resolve "$name")" || exit 1
    if [ ! -f "$PROJECT_DIR/.build/release/$binary" ]; then
        echo -e "  ${RED}$binary binary not found${RESET}"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "  Run 'swift build -c release' first"
    exit 1
fi
echo -e "${GREEN}Binaries found${RESET}"
echo

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Install each bridge
for name in "${bridges[@]}"; do
    read -r label binary port <<< "$(resolve "$name")"
    plist="$LAUNCHD_DIR/$label.plist"
    target="$TARGET_DIR/$label.plist"

    echo "Installing $label..."

    # Unload if already loaded
    if launchctl list | grep -q "$label"; then
        echo "  Unloading existing service..."
        launchctl unload "$target" 2>/dev/null || true
    fi

    # Copy plist
    echo "  Copying to $TARGET_DIR/"
    cp "$plist" "$target"

    # Load and start the service
    echo "  Loading service..."
    launchctl load "$target"
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

for name in "${bridges[@]}"; do
    read -r label binary port <<< "$(resolve "$name")"
    status=$(curl -s "http://localhost:$port/health" 2>/dev/null | grep -o '"ok":true' || echo "")

    if [ -n "$status" ]; then
        echo -e "  ${GREEN}$binary running on port $port${RESET}"
    else
        echo -e "  ${YELLOW}$binary may not be running (port $port)${RESET}"
    fi
done

echo
echo -e "${BOLD}Logs:${RESET}"
echo "   Startup logs: ~/Library/Logs/*-bridge.log (stdout/stderr from launchd)"
echo "   Request logs: log stream --predicate 'subsystem == \"com.user.bridge\"' --level info"
echo
echo -e "${GREEN}Installation complete!${RESET}"
