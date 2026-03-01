# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Unified Swift HTTP bridge for macOS native applications. A single Vapor server on port 7330 exposes REST APIs for 9 native apps via namespaced route prefixes (e.g. `/mail/messages`, `/calendar/events`). Requires macOS 14+.

## Build and Test Commands

```bash
swift build              # Debug build
swift build -c release   # Release build
swift test               # Run BridgeCore unit tests
swift package clean      # Clean build artifacts
./scripts/format.sh      # Format all Swift files (uses .swift-format config)
```

## Project Structure

```
Sources/
  BridgeCore/             # Shared library (middleware, markdown, rate limiter, response helper)
  MacBridge/
    main.swift            # Entry point, global middleware, root endpoints
    BridgeError.swift     # Shared error type for JXA bridges
    Config.swift          # Config file + env var loading
    API/                  # Framework integration and business logic (one per bridge)
    Routes/               # Route registration functions (one per bridge)
Tests/
  BridgeCoreTests/        # Unit tests for BridgeCore
launchd/                  # LaunchAgent plist template
scripts/                  # install, uninstall, start, stop, format
```

## Architecture

### BridgeCore (shared library)

All bridges depend on `BridgeCore` which provides:
- **`Middleware.swift`** — `FormatMiddleware` (markdown-by-default response conversion), `LoggingMiddleware` (request/response logging), `RateLimitMiddleware` (per-IP rate limiting)
- **`Markdown.swift`** — `jsonToMarkdown`, `arrayToMarkdownTable`, `objectToKeyValueList`, `formatCellValue` (converts JSON responses to markdown tables/lists)
- **`RateLimiter.swift`** — actor-based per-IP sliding window rate limiter
- **`Response.swift`** — `responseJSON()` helper for consistent `{"ok": true, "result": ...}` responses

### Bridge Pattern

Single server (`main.swift`) with route groups per bridge:
1. `main.swift` creates one Vapor app with global middleware
2. Each bridge has an API file (`API/*.swift`) and a routes file (`Routes/*.swift`)
3. Routes are registered via `register*Routes(on: app.grouped("prefix"), api: ...)`
4. Every bridge has `help`, `health`, and `schema` endpoints under its prefix

### Route Prefixes

| Prefix | App |
|--------|-----|
| `/calendar` | Calendar (EventKit) |
| `/contacts` | Contacts (CNContact) |
| `/mail` | Mail (ScriptingBridge) |
| `/things` | Things 3 (JXA) |
| `/notes` | Notes (JXA) |
| `/nnw` | NetNewsWire (JXA) |
| `/reminders` | Reminders (JXA) |
| `/messages` | Messages (JXA) |
| `/shortcuts` | Shortcuts (JXA) |

### Response Format

Responses are JSON by default (`{"ok": true, "result": ...}`). The `FormatMiddleware` converts JSON to markdown unless `?format=json` or `Accept: application/json` is present.

### API Layer (`API/*.swift`)

- Native frameworks (EventKit, Contacts): handle async permission requests, use guard for access control
- ScriptingBridge apps (Mail): use `SBApplication(bundleIdentifier:)` + KVC (`value(forKey:)`)
- JXA apps (Things, Notes, NetNewsWire, Reminders, Messages, Shortcuts): use `NSAppleScript` with JavaScript for Automation
- All return `[[String: Any]]` or `[String: Any]` for JSON serialization

## Adding New Bridges

1. Create `Sources/MacBridge/API/NewAppAPI.swift` with framework logic
2. Create `Sources/MacBridge/Routes/NewAppRoutes.swift` with a `registerNewAppRoutes(on:api:)` function
3. Register in `main.swift`: instantiate API, call `registerNewAppRoutes(on: app.grouped("newapp"), api: ...)`
4. Add to the `bridges` array in `main.swift` for aggregate health/index

## Key Conventions

- Endpoint naming: `GET /prefix/resources` (list), `GET /prefix/resource?id=...` (single), `POST /prefix/resources` (create), `POST /prefix/resources/delete` (delete)
- Error responses: `Abort(.badRequest, reason: "...")` for validation; `{"ok": false, "error": "..."}` for operation failures
- Configuration: `~/.config/mac-bridge/config` file with `key = value` lines (see `Config.swift`). Env vars override file values: `MACBRIDGE_PORT`, `MACBRIDGE_RATE_LIMIT`, `MACBRIDGE_DISABLED`, `MACBRIDGE_ARCHIVE_MAILBOXES`
- ScriptingBridge headers: generate with `sdef /path/to/App.app | sdp -fh --basename AppName`
- Never use clang-format on Swift — use `swift-format` (configured in `.swift-format`)

## Deployment

```bash
swift build -c release
./scripts/install.sh      # Copy plist to ~/Library/LaunchAgents/, load service
./scripts/uninstall.sh    # Stop and remove service
./scripts/start.sh        # Start (or restart) service
./scripts/stop.sh         # Stop service
```

Startup logs: `~/Library/Logs/macbridge.log` (stdout/stderr from launchd)
Request logs: `log stream --predicate 'subsystem == "com.user.mac-bridge"' --level info`
