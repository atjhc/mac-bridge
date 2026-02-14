# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift-based HTTP bridges for macOS native applications. Bridges use native frameworks (EventKit, Contacts) or ScriptingBridge instead of AppleScript/JXA, providing 10-100x performance improvements and better reliability.

**Project Structure:**
```
swift-bridge/
├── Package.swift              # SPM configuration
├── Sources/
│   ├── CalendarBridge/       # EventKit bridge (port 7334)
│   ├── ContactsBridge/       # Contacts bridge (port 7335)
│   └── MailBridge/           # ScriptingBridge bridge (port 7333)
├── launchd/                   # LaunchAgent plist templates
├── scripts/
│   ├── install.sh            # Install and start services
│   └── uninstall.sh          # Stop and remove services
└── .build/release/           # Compiled binaries (after build)
```

## Build Commands

```bash
# Build all bridges in release mode
swift build -c release

# Build for development (faster, includes debug symbols)
swift build

# Clean build artifacts
swift package clean

# Update dependencies
swift package update

# Format all Swift files
./scripts/format.sh
```

Binaries are output to `.build/release/` or `.build/debug/`.

## Running Bridges

**Development:**
```bash
# Run Calendar bridge (port 7334)
.build/release/CalendarBridge

# Run Contacts bridge with custom port
CONTACTS_BRIDGE_PORT=7335 DEBUG=1 .build/release/ContactsBridge

# Run Mail bridge
MAIL_BRIDGE_PORT=7333 DEBUG=1 .build/release/MailBridge
```

**Production (LaunchAgents):**
- Calendar: `~/Library/LaunchAgents/com.user.calendar-bridge-swift.plist`
- Contacts: `~/Library/LaunchAgents/com.user.contacts-bridge-swift.plist`
- Mail: `~/Library/LaunchAgents/com.user.mail-bridge-swift.plist`

Control via launchctl:
```bash
launchctl stop com.user.calendar-bridge-swift
launchctl start com.user.calendar-bridge-swift
```

## Architecture

### Bridge Structure Pattern

Each bridge follows this consistent pattern:

```
Sources/
  BridgeName/
    BridgeNameAPI.swift    # Framework integration + business logic
    main.swift             # Vapor HTTP server + endpoint definitions
```

### API Layer (`*API.swift`)
- Wraps native macOS framework (EventKit, Contacts) or ScriptingBridge (Mail)
- For native frameworks: handles async permission requests
- For ScriptingBridge: uses `SBApplication` and generated header from `sdef`
- Provides typed methods that return `[[String: Any]]` dictionaries (for JSON serialization)
- Uses guard statements for access control

**Example pattern:**
```swift
class BridgeNameAPI {
    private let store = NativeFrameworkStore()
    private var hasAccess = false
    
    init() {
        Task { await requestAccess() }
    }
    
    private func ensureAccess() throws {
        guard hasAccess else { throw accessError }
    }
    
    func getData() async throws -> [[String: Any]] {
        try ensureAccess()
        // Framework operations
    }
}
```

### HTTP Layer (`main.swift`)
- Creates Vapor application
- Instantiates API class
- Defines REST endpoints using `app.get()`, `app.post()`
- All responses use `responseJSON()` helper for consistent `{ok: true, result: ...}` format
- Includes `/health` and `/schema` endpoints on every bridge
- Custom middleware:
  - `RateLimitMiddleware` - Per-IP rate limiting per second (configurable via RATE_LIMIT_PER_SECOND)
  - `LoggingMiddleware` - Request/response logging for DEBUG mode

**Response format:**
```swift
func responseJSON(_ value: Any) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: value)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}
```

## Adding New Bridges

1. **Create directory structure:**
   ```bash
   mkdir -p Sources/NewBridge
   ```

2. **Implement API class** (`Sources/NewBridge/NewBridgeAPI.swift`):
   - Import relevant framework (`import FrameworkName`)
   - Create store/manager instance
   - Request permissions in `init()`
   - Implement data access methods

3. **Implement HTTP server** (`Sources/NewBridge/main.swift`):
   - Copy structure from existing bridge
   - Update app name in health/schema endpoints
   - Define REST endpoints using Vapor routes
   - Use `responseJSON()` for all responses

4. **Update Package.swift:**
   ```swift
   .executableTarget(
       name: "NewBridge",
       dependencies: [
           .product(name: "Vapor", package: "vapor")
       ]
   )
   ```

5. **Create LaunchAgent plist** (`~/Library/LaunchAgents/com.user.newbridge-swift.plist`):
   - Set ProgramArguments to `.build/release/NewBridge`
   - Add port/DEBUG environment variables
   - Set RunAtLoad and KeepAlive to true
   - Configure log paths in `/Users/james/Library/Logs/`

## Key Patterns & Conventions

### Environment Variables
- `{BRIDGE_NAME}_PORT` - Port number (e.g., CALENDAR_BRIDGE_PORT=7334)
- `DEBUG` - Set to "1" to enable request/response logging
- `RATE_LIMIT_PER_SECOND` - Maximum requests per IP per second (default: 10)

### Endpoint Naming
- List resources: `GET /resource` (plural)
- Get single: `GET /resource?id=...` (singular)
- Create: `POST /resource` (plural)
- Delete: `POST /resource/delete` (not RESTful DELETE due to body requirements)

### Error Handling
- Use `Abort(.badRequest, reason: "...")` for validation errors
- Return `{ok: false, error: "..."}` for operation failures
- Let framework errors propagate (Vapor handles them)

### Data Serialization
- API methods return `[[String: Any]]` for arrays or `[String: Any]` for objects
- Dates: Convert to ISO8601 strings via `.toISOString()`
- IDs: Convert to String if needed for JSON compatibility
- Use try-catch in closures for optional properties: `(() => { try { return value } catch { return null } })()`

## macOS Framework Notes

### EventKit (Calendar)
- Requires `requestFullAccessToEvents()` (macOS 14+)
- Status filtering: `.none` for inbox items, `.confirmed` for accepted events
- Siri suggestions have `messages://` or `mail://` URLs

### Contacts
- Use `CNContactFormatter.descriptorForRequiredKeys(for: .fullName)` to fetch required name properties
- Boolean status: `readStatus() !== 'unread'`, not `.read()` property
- Fetch specific keys via `keysToFetch` array for performance

## Deployment

### Initial Installation

```bash
swift build -c release
./scripts/install.sh
```

The install script will:
- Copy plists from `launchd/` to `~/Library/LaunchAgents/`
- Load and start both services
- Verify they're running

### Uninstalling

```bash
./scripts/uninstall.sh
```

### After Code Changes

When rebuilding:
1. `swift build -c release`
2. `./scripts/install.sh` (will restart services with new binaries)

Or manually:
1. `swift build -c release`
2. `launchctl stop com.user.{bridge}-swift`
3. `launchctl start com.user.{bridge}-swift`
4. Verify with: `curl http://localhost:PORT/health`

Logs are in `/Users/james/Library/Logs/{bridge}.log` (combined stdout/stderr).

### LaunchAgent Templates

LaunchAgent plists are version-controlled in `launchd/`:
- `com.user.calendar-bridge-swift.plist`
- `com.user.contacts-bridge-swift.plist`

Edit these templates to change configuration, then run `./scripts/install.sh` to apply.
