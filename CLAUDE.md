# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift HTTP bridges for macOS native applications. Each bridge exposes a local REST API backed by native frameworks (EventKit, Contacts) or ScriptingBridge. Built on Hummingbird, requires macOS 14+.

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
  BridgeCore/             # Framework-agnostic shared library (markdown, rate limiter, response types, health checks)
  BridgeHTTP/             # Hummingbird adapter (middleware, response conversion)
  CalendarBridge/         # EventKit (port 7334)
  ContactsBridge/         # Contacts framework (port 7335)
  MailBridge/             # ScriptingBridge (port 7333)
  ThingsBridge/           # ScriptingBridge (port 7332)
  NotesBridge/            # ScriptingBridge (port 7336)
  NetNewsWireBridge/      # ScriptingBridge (port 7331)
Tests/
  BridgeCoreTests/        # Unit tests for BridgeCore
launchd/                  # LaunchAgent plist template
scripts/                  # install, uninstall, start, stop, format
```

Each bridge has two files:
- `*API.swift` — framework integration and business logic (framework-agnostic, imports only `BridgeCore`)
- `main.swift` — Hummingbird HTTP server and route definitions

## Architecture

### Module Dependency Graph

```
BridgeCore (pure Swift, no HTTP framework)
    ↑
BridgeHTTP (Hummingbird adapter)
    ↑
Each bridge (CalendarBridge, MailBridge, etc.)
```

To swap Hummingbird for another framework: replace `BridgeHTTP` and the `main.swift` files. `BridgeCore` and all `*API.swift` files stay untouched.

### BridgeCore (framework-agnostic shared library)

- **`Response.swift`** — `BridgeResponse` struct (data + content type + status code), `responseJSON()` and `markdownResponse()` helpers, `formatJSONAsMarkdown()` for markdown conversion
- **`Markdown.swift`** — `jsonToMarkdown`, `arrayToMarkdownTable`, `objectToKeyValueList`, `formatCellValue` (converts JSON responses to markdown tables/lists)
- **`RateLimiter.swift`** — actor-based per-IP sliding window rate limiter
- **`AppHealth.swift`** — `buildHealthResult()`, `isAppInstalled()`, `isAppRunning()` for health endpoint support

### BridgeHTTP (Hummingbird adapter)

- **`HBResponse.swift`** — `BridgeResponse.hbResponse()` conversion, `bridgeResponse()` helper that auto-formats as markdown or JSON via `BridgeFormat` TaskLocal, `@_exported import BridgeCore`
- **`HBMiddleware.swift`** — `BridgeRateLimitMiddleware` (per-IP rate limiting), `BridgeLoggingMiddleware` (request/response logging), `BridgeFormatMiddleware` (sets `BridgeFormat.wantsJSON` TaskLocal based on `?format=json` or `Accept` header)

### Bridge Pattern

Each bridge's `main.swift`:
1. Imports `BridgeHTTP` and `Hummingbird`
2. Creates a `Router`, adds shared middleware, defines routes
3. Routes call API methods and return via `bridgeResponse()` (auto-handles markdown/JSON format)
4. Creates `Application(router:configuration:)` and calls `try await app.runService()`
5. Every bridge has `/help`, `/health`, and `/schema` endpoints

### Health Endpoints

Each API class has a `healthCheck() -> [String: Any]` method:
- **SBApplication bridges (Mail)**: checks `SBApplication.isRunning`
- **JXA bridges (Things, Notes, NNW)**: checks `NSWorkspace` for app installed/running state
- **Native frameworks (Calendar, Contacts)**: reports `hasAccess` permission flag

### Response Format

Responses are markdown by default (tables for lists, key-value for single objects). The `BridgeFormatMiddleware` sets a TaskLocal flag, and `bridgeResponse()` returns JSON when `?format=json` or `Accept: application/json` is present. JSON responses use `{"ok": true, "result": ...}`.

### API Layer (`API/*.swift`)

- Native frameworks (EventKit, Contacts): handle async permission requests, use guard for access control
- ScriptingBridge apps (Mail, Things, Notes, NetNewsWire): use `SBApplication(bundleIdentifier:)` + KVC (`value(forKey:)`) or JXA via osascript
- All return `[[String: Any]]` or `[String: Any]` for JSON serialization
- Import only `BridgeCore` — never import HTTP framework types

## Adding New Bridges

1. Create `Sources/NewBridge/NewBridgeAPI.swift` with framework logic (import `BridgeCore`)
2. Create `Sources/NewBridge/main.swift` — import `BridgeHTTP` and `Hummingbird`, set up middleware, define routes
3. Add to `Package.swift`:
   ```swift
   .executableTarget(
       name: "NewBridge",
       dependencies: ["BridgeHTTP"]
   )
   ```
4. Create LaunchAgent plist in `launchd/`

## Key Conventions

- Endpoint naming: `GET /resources` (list), `GET /resource?id=...` (single), `POST /resources` (create), `POST /resources/delete` (delete)
- Error responses: `throw HTTPError(.badRequest, message: "...")` for validation; `{"ok": false, "error": "..."}` for operation failures
- Environment variables: `{BRIDGE_NAME}_PORT` for port, `RATE_LIMIT_PER_SECOND` for rate limit (default: 10)
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
