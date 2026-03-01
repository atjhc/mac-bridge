# Mac Bridge

Unified Swift HTTP bridge for macOS applications. A single server on port 7330 exposes REST APIs for 9 native apps via namespaced route prefixes.

Built on [Vapor](https://vapor.codes). Requires macOS 14+.

## Bridges

| Prefix | Framework | App |
| --- | --- | --- |
| `/calendar` | EventKit | Calendar |
| `/contacts` | Contacts | Contacts |
| `/mail` | ScriptingBridge | Mail |
| `/things` | JXA | Things 3 |
| `/notes` | JXA | Notes |
| `/nnw` | JXA | NetNewsWire |
| `/reminders` | JXA | Reminders |
| `/messages` | JXA | Messages |
| `/shortcuts` | JXA | Shortcuts |

Every bridge provides `help`, `health`, and `schema` endpoints under its prefix (e.g. `/mail/help`, `/things/health`).

### Global endpoints

- `GET /` — list all bridges with current health status
- `GET /health` — aggregate health (`ok` or `degraded`)
- `GET /help` — overview of all bridges and prefixes

### Response format

All endpoints return **markdown** by default (tables for lists, key-value pairs for single objects). Add `?format=json` or send `Accept: application/json` to get JSON responses in `{"ok": true, "result": ...}` format.

## Building

```bash
swift build -c release
```

Binary is output to `.build/release/MacBridge`.

## Testing

```bash
swift test
```

The `BridgeCore` library has unit tests covering markdown conversion, cell formatting (including boolean detection), and rate limiting.

## Running

### Development

```bash
# Run directly
.build/release/MacBridge

# Override port via environment
MACBRIDGE_PORT=8080 .build/release/MacBridge
```

### Production (LaunchAgent)

```bash
# Install and start service
./scripts/install.sh

# Start / stop without reinstalling
./scripts/start.sh
./scripts/stop.sh

# Uninstall service
./scripts/uninstall.sh
```

### Logs

Startup logs (stdout/stderr from launchd):
```bash
tail -f ~/Library/Logs/macbridge.log
```

Request logs (via OSLog):
```bash
log stream --predicate 'subsystem == "com.user.mac-bridge"' --level info
```

## Project structure

```
Sources/
  BridgeCore/             # Shared library
    Markdown.swift        # JSON-to-markdown conversion
    Middleware.swift       # FormatMiddleware, LoggingMiddleware, RateLimitMiddleware
    RateLimiter.swift     # Per-IP rate limiting actor
    Response.swift        # responseJSON() helper
    HealthCheck.swift     # App health check (installed/running)
  MacBridge/
    main.swift            # Entry point, global middleware, root endpoints
    BridgeError.swift     # Shared error type for JXA bridges
    Config.swift          # Config file + env var loading
    API/                  # Framework integration and business logic (one per bridge)
    Routes/               # Route registration functions (one per bridge)
Tests/
  BridgeCoreTests/        # Unit tests for shared library
launchd/                  # LaunchAgent plist template
scripts/
  install.sh              # Install and load LaunchAgent
  uninstall.sh            # Stop and remove LaunchAgent
  start.sh                # Start (or restart) service
  stop.sh                 # Stop service
  format.sh               # Run swift-format
```

## Configuration

Settings are read from `~/.config/mac-bridge/config` (if it exists), then overridden by environment variables.

### Config file

Simple `key = value` format. Blank lines and `#` comments are ignored.

```
# ~/.config/mac-bridge/config

port = 7330
rate-limit = 10
disabled = nnw, things
archive-mailboxes = Work=Archive, Personal=All Mail
```

### Keys

| Key | Default | Description |
| --- | --- | --- |
| `port` | `7330` | Port number |
| `rate-limit` | `10` | Max requests per IP per second |
| `disabled` | _(none)_ | Comma-separated bridge prefixes to disable (e.g. `nnw, things`) |
| `archive-mailboxes` | _(none)_ | Mail archive mailbox mapping (format: `Account=Mailbox, Account2=Mailbox`) |

### Environment variables

Environment variables override config file values:

- `MACBRIDGE_PORT` → `port`
- `MACBRIDGE_RATE_LIMIT` → `rate-limit`
- `MACBRIDGE_DISABLED` → `disabled`
- `MACBRIDGE_ARCHIVE_MAILBOXES` → `archive-mailboxes`

## Adding a new bridge

1. Create `Sources/MacBridge/API/NewAppAPI.swift` with framework logic
2. Create `Sources/MacBridge/Routes/NewAppRoutes.swift` with a `registerNewAppRoutes(on:api:)` function
3. Register in `main.swift`: instantiate API, call `registerNewAppRoutes(on: app.grouped("newapp"), api: ...)`, add to the `bridges` array
