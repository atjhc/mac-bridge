#!/bin/bash
set -e

# Swift Bridge LaunchAgent Uninstallation Script
# Stops and unloads CalendarBridge, ContactsBridge, and MailBridge LaunchAgents

TARGET_DIR="$HOME/Library/LaunchAgents"

echo "🗑️  Swift Bridge LaunchAgent Uninstaller"
echo "========================================="
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
        
        echo "✓ $label removed"
        echo
    else
        echo "⚠️  $label not found (already removed?)"
        echo
    fi
done

echo "🎉 Uninstallation complete!"
echo
echo "Note: Binaries in .build/release/ were not removed"
echo "      Logs in ~/Library/Logs/ were not removed"
