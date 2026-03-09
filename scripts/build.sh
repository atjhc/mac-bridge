#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IDENTITY="Heimdall"
BINARY="$PROJECT_DIR/.build/release/MacBridge"

swift build -c release --product MacBridge

# Unlock keychain if needed (prompts for password over SSH)
if ! codesign --force --sign "$IDENTITY" --identifier "com.user.macbridge" "$BINARY" 2>/dev/null; then
    read -s -p "Keychain password: " KC_PASS
    echo
    security unlock-keychain -p "$KC_PASS" login.keychain-db
    codesign --force --sign "$IDENTITY" --identifier "com.user.macbridge" "$BINARY"
fi

echo "Signed $BINARY with identity '$IDENTITY'"

SERVICE="com.user.macbridge"
if launchctl list | grep -q "$SERVICE"; then
    launchctl stop "$SERVICE"
    launchctl start "$SERVICE"
    echo "Restarted $SERVICE"
fi
