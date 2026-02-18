# Mac Bridge

Native Swift HTTP bridges for macOS applications. Each bridge exposes a local REST API backed by native frameworks (EventKit, Contacts) or ScriptingBridge, giving 10-100x performance over AppleScript/JXA with better reliability.

Built on [Vapor](https://vapor.codes). Requires macOS 14+.

## Bridges

| Bridge | Port | Framework | App |
| --- | --- | --- | --- |
| CalendarBridge | 7334 | EventKit | Calendar |
| ContactsBridge | 7335 | Contacts | Contacts |
| MailBridge | 7333 | ScriptingBridge | Mail |
| ThingsBridge | 7332 | ScriptingBridge | Things 3 |
| NotesBridge | 7336 | ScriptingBridge | Notes |
| NetNewsWireBridge | 7331 | ScriptingBridge | NetNewsWire |

Every bridge provides `/help` (markdown API docs), `/health`, and `/schema` (machine-readable endpoint definitions).

### Response format

All endpoints return **markdown** by default (tables for lists, key-value pairs for single objects). Add `?format=json` or send `Accept: application/json` to get JSON responses in `{"ok": true, "result": ...}` format.

## Building

```bash
swift build -c release
```

Binaries are output to `.build/release/`.

## Testing

```bash
swift test
```

The `BridgeCore` library has unit tests covering markdown conversion, cell formatting (including boolean detection), and rate limiting.

## Running

### Development

```bash
# Run any bridge directly
.build/release/CalendarBridge

# Override port via environment
MAIL_BRIDGE_PORT=7333 .build/release/MailBridge
```

### Production (LaunchAgents)

All scripts accept optional bridge names (`calendar`, `contacts`, `mail`). No arguments means all bridges.

```bash
# Install and start services
./scripts/install.sh                # all bridges
./scripts/install.sh calendar mail  # specific bridges

# Start / stop without reinstalling
./scripts/start.sh
./scripts/stop.sh contacts

# Uninstall services
./scripts/uninstall.sh
```

### Logs

Startup logs (stdout/stderr from launchd):
```bash
tail -f ~/Library/Logs/calendar-bridge.log
```

Request logs (via OSLog):
```bash
log stream --predicate 'subsystem == "com.user.bridge"' --level info
```

## Project structure

```
Sources/
  BridgeCore/             # Shared library
    Markdown.swift        # JSON-to-markdown conversion
    Middleware.swift       # FormatMiddleware, LoggingMiddleware, RateLimitMiddleware
    RateLimiter.swift     # Per-IP rate limiting actor
    Response.swift        # responseJSON() helper
  CalendarBridge/         # EventKit bridge (port 7334)
    CalendarAPI.swift
    main.swift
  ContactsBridge/         # Contacts bridge (port 7335)
    ContactsAPI.swift
    main.swift
  MailBridge/             # ScriptingBridge bridge (port 7333)
    Mail.h
    MailBridgeAPI.swift
    main.swift
  ThingsBridge/           # ScriptingBridge bridge (port 7332)
    ThingsAPI.swift
    main.swift
  NotesBridge/            # ScriptingBridge bridge (port 7336)
    NotesAPI.swift
    main.swift
  NetNewsWireBridge/      # ScriptingBridge bridge (port 7331)
    NetNewsWireAPI.swift
    main.swift
Tests/
  BridgeCoreTests/        # Unit tests for shared library
launchd/                  # LaunchAgent plist templates
scripts/
  install.sh              # Install and load LaunchAgents
  uninstall.sh            # Stop and remove LaunchAgents
  start.sh                # Start (or restart) services
  stop.sh                 # Stop services
  format.sh               # Run swift-format
```

## Environment variables

- `{BRIDGE_NAME}_PORT` - Port number (e.g. `CALENDAR_BRIDGE_PORT=7334`)
- `RATE_LIMIT_PER_SECOND` - Max requests per IP per second (default: 10)
- `ARCHIVE_MAILBOXES` - Mail bridge archive mailbox config (format: `Account1=Mailbox,Account2=Mailbox`)

## Adding a new bridge

1. Create `Sources/NewBridge/NewBridgeAPI.swift` with framework logic
2. Create `Sources/NewBridge/main.swift` with Vapor routes (import BridgeCore for shared middleware/helpers)
3. Add executable target to `Package.swift` with `BridgeCore` dependency
4. Create LaunchAgent plist in `launchd/`
