#!/bin/bash
set -e

# Stop MacBridge LaunchAgent
# Usage: ./scripts/stop.sh

LABEL="com.user.macbridge"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

if ! launchctl list | grep -q "$LABEL"; then
    echo -e "${YELLOW}$LABEL not running${RESET}"
    exit 0
fi

launchctl stop "$LABEL" 2>/dev/null || true
echo -e "${GREEN}$LABEL stopped${RESET}"
