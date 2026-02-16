#!/bin/bash
set -e

# Stop bridge LaunchAgents
# Usage: ./scripts/stop.sh [bridge...]
# Examples:
#   ./scripts/stop.sh              # stop all
#   ./scripts/stop.sh calendar     # stop one
#   ./scripts/stop.sh mail contacts

TARGET_DIR="$HOME/Library/LaunchAgents"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# Map short names to launchd labels
resolve_label() {
    case "$1" in
        calendar) echo "com.user.calendar-bridge-swift" ;;
        contacts) echo "com.user.contacts-bridge-swift" ;;
        mail)     echo "com.user.mail-bridge-swift" ;;
        *)        echo "$1" ;;
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
    )
fi

for label in "${labels[@]}"; do
    if ! launchctl list | grep -q "$label"; then
        echo -e "${YELLOW}$label not running${RESET}"
        continue
    fi

    launchctl stop "$label" 2>/dev/null || true
    echo -e "${GREEN}$label stopped${RESET}"
done
