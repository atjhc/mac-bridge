#!/bin/bash
set -e

# Swift Bridge LaunchAgent Installation Script
# Installs and loads CalendarBridge, ContactsBridge, and MailBridge LaunchAgents

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCHD_DIR="$PROJECT_DIR/launchd"
TARGET_DIR="$HOME/Library/LaunchAgents"

echo "🚀 Swift Bridge LaunchAgent Installer"
echo "======================================="
echo

# Check if binaries exist
echo "Checking for release binaries..."
if [ ! -f "$PROJECT_DIR/.build/release/CalendarBridge" ]; then
    echo "❌ CalendarBridge binary not found"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/.build/release/ContactsBridge" ]; then
    echo "❌ ContactsBridge binary not found"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/.build/release/MailBridge" ]; then
    echo "❌ MailBridge binary not found"
    echo "   Run 'swift build -c release' first"
    exit 1
fi
echo "✓ Binaries found"
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
    
    echo "✓ $label installed and started"
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
    echo "✓ Calendar Bridge running on port 7334"
else
    echo "⚠️  Calendar Bridge may not be running"
fi

if [ -n "$contacts_status" ]; then
    echo "✓ Contacts Bridge running on port 7335"
else
    echo "⚠️  Contacts Bridge may not be running"
fi

if [ -n "$mail_status" ]; then
    echo "✓ Mail Bridge running on port 7333"
else
    echo "⚠️  Mail Bridge may not be running"
fi

echo
echo "📝 Logs are available at:"
echo "   ~/Library/Logs/calendar-bridge.log"
echo "   ~/Library/Logs/contacts-bridge.log"
echo "   ~/Library/Logs/mail-bridge.log"
echo
echo "🎉 Installation complete!"
