#!/bin/bash
set -e

# Start bridge LaunchAgents
# Usage: ./scripts/start.sh [bridge...]
# Examples:
#   ./scripts/start.sh              # start all
#   ./scripts/start.sh calendar     # start one
#   ./scripts/start.sh mail contacts

TARGET_DIR="$HOME/Library/LaunchAgents"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# Map short names to launchd labels
resolve_label() {
    case "$1" in
        calendar) echo "com.user.calendar-bridge-swift" ;;
        contacts) echo "com.user.contacts-bridge-swift" ;;
        mail)     echo "com.user.mail-bridge-swift" ;;
        things)   echo "com.user.things-bridge-swift" ;;
        notes)    echo "com.user.notes-bridge-swift" ;;
        nnw)       echo "com.user.nnw-bridge-swift" ;;
        reminders) echo "com.user.reminders-bridge-swift" ;;
        messages)  echo "com.user.messages-bridge-swift" ;;
        shortcuts) echo "com.user.shortcuts-bridge-swift" ;;
        *)         echo "$1" ;;
    esac
}

if [ $# -gt 0 ]; then
    labels=()
    for name in "$@"; do
        labels+=("$(resolve_label "$name")")
    done
else
    labels=(
        "com.user.calendar-bridge-swift"
        "com.user.contacts-bridge-swift"
        "com.user.mail-bridge-swift"
        "com.user.things-bridge-swift"
        "com.user.notes-bridge-swift"
        "com.user.nnw-bridge-swift"
        "com.user.reminders-bridge-swift"
        "com.user.messages-bridge-swift"
        "com.user.shortcuts-bridge-swift"
    )
fi

for label in "${labels[@]}"; do
    plist="$TARGET_DIR/$label.plist"

    if [ ! -f "$plist" ]; then
        echo -e "${RED}$label not installed${RESET}"
        echo "  Run ./scripts/install.sh first"
        continue
    fi

    if launchctl list | grep -q "$label"; then
        echo -e "${YELLOW}$label already running, restarting...${RESET}"
        launchctl stop "$label" 2>/dev/null || true
    fi

    launchctl start "$label"
    echo -e "${GREEN}$label started${RESET}"
done
