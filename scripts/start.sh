#!/bin/bash
set -e

# Start MacBridge LaunchAgent
# Usage: ./scripts/start.sh

TARGET_DIR="$HOME/Library/LaunchAgents"
LABEL="com.user.macbridge"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

PLIST="$TARGET_DIR/$LABEL.plist"

if [ ! -f "$PLIST" ]; then
    echo -e "${RED}$LABEL not installed${RESET}"
    echo "  Run ./scripts/install.sh first"
    exit 1
fi

if launchctl list | grep -q "$LABEL"; then
    echo -e "${YELLOW}$LABEL already running, restarting...${RESET}"
    launchctl stop "$LABEL" 2>/dev/null || true
fi

launchctl start "$LABEL"
echo -e "${GREEN}$LABEL started${RESET}"
