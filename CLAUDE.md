# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift HTTP bridges for macOS native applications. Each bridge exposes a local REST API backed by native frameworks (EventKit, Contacts) or ScriptingBridge. Built on Vapor, requires macOS 14+.

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
  CalendarBridge/         # EventKit (port 7334)
  ContactsBridge/         # Contacts framework (port 7335)
  MailBridge/             # ScriptingBridge (port 7333)
  ThingsBridge/           # ScriptingBridge (port 7332)
  NotesBridge/            # ScriptingBridge (port 7336)
  NetNewsWireBridge/      # ScriptingBridge (port 7331)
Tests/
  BridgeCoreTests/        # Unit tests for BridgeCore
launchd/                  # LaunchAgent plist templates
scripts/                  # install, uninstall, start, stop, format
```

Each bridge has two files:
- `*API.swift` — framework integration and business logic
- `main.swift` — Vapor HTTP server and route definitions

## Architecture

### BridgeCore (shared library)

All bridges depend on `BridgeCore` which provides:
- **`Middleware.swift`** — `FormatMiddleware` (markdown-by-default response conversion), `LoggingMiddleware` (request/response logging), `RateLimitMiddleware` (per-IP rate limiting)
- **`Markdown.swift`** — `jsonToMarkdown`, `arrayToMarkdownTable`, `objectToKeyValueList`, `formatCellValue` (converts JSON responses to markdown tables/lists)
- **`RateLimiter.swift`** — actor-based per-IP sliding window rate limiter
- **`Response.swift`** — `responseJSON()` helper for consistent `{"ok": true, "result": ...}` responses

### Bridge Pattern

Each bridge's `main.swift`:
1. Imports `Vapor` and `BridgeCore`
2. Creates a Vapor application and API instance
3. Wires up shared middleware (rate limit, logging, format)
4. Defines REST endpoints using `app.get()` / `app.post()`
5. Every bridge has `/help`, `/health`, and `/schema` endpoints

### Response Format

Responses are JSON by default (`{"ok": true, "result": ...}`). The `FormatMiddleware` converts JSON to markdown unless `?format=json` or `Accept: application/json` is present.

### API Layer (`*API.swift`)

- Native frameworks (EventKit, Contacts): handle async permission requests, use guard for access control
- ScriptingBridge apps (Mail, Things, Notes, NetNewsWire): use `SBApplication(bundleIdentifier:)` + KVC (`value(forKey:)`)
- All return `[[String: Any]]` or `[String: Any]` for JSON serialization

## Adding New Bridges

1. Create `Sources/NewBridge/NewBridgeAPI.swift` with framework logic
2. Create `Sources/NewBridge/main.swift` — import `BridgeCore`, set up middleware, define routes
3. Add to `Package.swift`:
   ```swift
   .executableTarget(
       name: "NewBridge",
       dependencies: [
           .product(name: "Vapor", package: "vapor"),
           "BridgeCore",
       ]
   )
   ```
4. Create LaunchAgent plist in `launchd/`

## Key Conventions

- Endpoint naming: `GET /resources` (list), `GET /resource?id=...` (single), `POST /resources` (create), `POST /resources/delete` (delete)
- Error responses: `Abort(.badRequest, reason: "...")` for validation; `{"ok": false, "error": "..."}` for operation failures
- Environment variables: `{BRIDGE_NAME}_PORT` for port, `RATE_LIMIT_PER_SECOND` for rate limit (default: 10)
- ScriptingBridge headers: generate with `sdef /path/to/App.app | sdp -fh --basename AppName`
- Never use clang-format on Swift — use `swift-format` (configured in `.swift-format`)

## Deployment

All scripts accept optional bridge short names (`calendar`, `contacts`, `mail`). No arguments means all bridges.

```bash
swift build -c release
./scripts/install.sh [bridge...]    # Copy plists to ~/Library/LaunchAgents/, load services
./scripts/uninstall.sh [bridge...]  # Stop and remove services
./scripts/start.sh [bridge...]      # Start (or restart) services
./scripts/stop.sh [bridge...]       # Stop services
```

Startup logs: `~/Library/Logs/{bridge}-bridge.log` (stdout/stderr from launchd)
Request logs: `log stream --predicate 'subsystem == "com.user.bridge"' --level info`
