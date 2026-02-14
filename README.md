# Swift Bridge

Native Swift bridges for macOS applications using system frameworks.

## Bridges

### Calendar Bridge (Port 7334)
Uses EventKit framework for fast, reliable Calendar.app access.

**Endpoints:**
- `GET /calendars` - List all calendars
- `GET /events` - List events (supports filters: calendar, from, to, limit, status, siri)
- `GET /event?id=...` - Get single event details
- `POST /events` - Create new event
- `POST /events/delete` - Delete events

**Environment:**
- `CALENDAR_BRIDGE_PORT` - Port to listen on (default: 7334)
- `DEBUG` - Enable debug logging (1 or 0)
- `RATE_LIMIT_PER_SECOND` - Max requests per IP per second (default: 10)

### Contacts Bridge (Port 7335)
Uses Contacts framework for fast, reliable Contacts.app access.

**Endpoints:**
- `GET /contacts` - List contacts (supports search, limit)
- `GET /contact?id=...` - Get single contact details
- `GET /search?email=...&phone=...` - Search by email or phone
- `POST /contacts` - Create new contact

**Environment:**
- `CONTACTS_BRIDGE_PORT` - Port to listen on (default: 7335)
- `DEBUG` - Enable debug logging (1 or 0)
- `RATE_LIMIT_PER_SECOND` - Max requests per IP per second (default: 10)

### Mail Bridge (Port 7333)
Uses ScriptingBridge framework for reliable Mail.app access.

**Endpoints:**
- `GET /accounts` - List email accounts
- `GET /mailboxes` - List mailboxes (supports account filter)
- `GET /messages` - List messages (supports filters: mailbox, account, unread, flagged, search, limit, offset)
- `GET /message?id=...` - Get single message with content (supports includeSource for raw email)
- `POST /messages/read` - Mark messages as read/unread
- `POST /messages/flag` - Flag/unflag messages
- `POST /messages/move` - Move messages to another mailbox
- `POST /messages/delete` - Delete messages
- `POST /compose` - Compose and send email

**Environment:**
- `MAIL_BRIDGE_PORT` - Port to listen on (default: 7333)
- `DEBUG` - Enable debug logging (1 or 0)
- `RATE_LIMIT_PER_SECOND` - Max requests per IP per second (default: 10)

## Building

```bash
swift build -c release
```

Binaries will be in `.build/release/`:
- `CalendarBridge`
- `ContactsBridge`
- `MailBridge`

## Running

### Development
```bash
# Calendar
.build/release/CalendarBridge

# Contacts
CONTACTS_BRIDGE_PORT=7335 .build/release/ContactsBridge

# Mail
MAIL_BRIDGE_PORT=7333 .build/release/MailBridge
```

### Production (LaunchAgents)

**Install and start services:**
```bash
./scripts/install.sh
```

This will:
- Copy plists from `launchd/` to `~/Library/LaunchAgents/`
- Load and start CalendarBridge, ContactsBridge, and MailBridge
- Verify services are running

**Uninstall services:**
```bash
./scripts/uninstall.sh
```

**Manual control:**
```bash
# Restart a service
launchctl stop com.user.calendar-bridge-swift
launchctl start com.user.calendar-bridge-swift

# View logs
tail -f ~/Library/Logs/calendar-bridge.log
tail -f ~/Library/Logs/contacts-bridge.log
tail -f ~/Library/Logs/mail-bridge.log
```

## Why Swift?

These bridges use native macOS frameworks (EventKit, Contacts) or ScriptingBridge instead of AppleScript/JXA:
- **10-100x faster** than AppleScript for native frameworks
- **More reliable** - no scripting quirks or timeouts
- **Better error handling** - proper Swift error types
- **Type safety** - compile-time guarantees
- **Full API access** - no scripting limitations

**Frameworks used:**
- **EventKit** (Calendar) - Direct framework access
- **Contacts** (Contacts) - Direct framework access
- **ScriptingBridge** (Mail) - Native Swift/ObjC bindings to scriptable apps

## Adding New Bridges

1. Create `Sources/NewBridge/` directory
2. Add `NewBridgeAPI.swift` with framework logic
3. Add `main.swift` with Vapor HTTP server
4. Update `Package.swift` to add new executable target
5. Create LaunchAgent plist in `~/Library/LaunchAgents/`
