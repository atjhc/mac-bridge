# MacBridge

Local HTTP API for macOS apps. A single server exposes REST endpoints for Calendar, Contacts, Mail, Messages, Notes, Reminders, Things 3, NetNewsWire, and Shortcuts.

Requires macOS 14+.

## Quick Start

```bash
swift build -c release
./scripts/install.sh
```

The server listens on `http://localhost:7330` by default.

## Bridges

Every bridge provides `GET /help`, `GET /health`, and `GET /schema` in addition to the endpoints listed below.

### Calendar `/calendar`

| Method | Path | Description |
|--------|------|-------------|
| GET | /calendar/calendars | List calendars |
| GET | /calendar/events | List events (filter by calendar, date range) |
| GET | /calendar/event | Get a single event |
| POST | /calendar/events | Create an event |
| POST | /calendar/events/delete | Delete events |

### Contacts `/contacts`

| Method | Path | Description |
|--------|------|-------------|
| GET | /contacts/contacts | List contacts |
| GET | /contacts/contact | Get a single contact |
| GET | /contacts/search | Search contacts |
| POST | /contacts/contacts | Create a contact |

### Mail `/mail`

| Method | Path | Description |
|--------|------|-------------|
| GET | /mail/accounts | List mail accounts |
| GET | /mail/mailboxes | List mailboxes |
| GET | /mail/messages | List messages (filter by mailbox, account, read/flagged status) |
| GET | /mail/message | Get a single message with full content |
| POST | /mail/messages/read | Mark messages read/unread |
| POST | /mail/messages/flag | Flag/unflag messages |
| POST | /mail/messages/move | Move messages between mailboxes |
| POST | /mail/messages/archive | Archive messages |
| POST | /mail/messages/delete | Delete messages |
| POST | /mail/compose | Send a new email |

### Messages `/messages`

| Method | Path | Description |
|--------|------|-------------|
| GET | /messages/chats | List chats |
| GET | /messages/chat | Get a single chat |
| GET | /messages/participants | List participants in a chat |
| POST | /messages/send | Send a message |

### Notes `/notes`

| Method | Path | Description |
|--------|------|-------------|
| GET | /notes/accounts | List accounts |
| GET | /notes/folders | List folders |
| GET | /notes/notes | List notes |
| GET | /notes/note | Get a single note |
| GET | /notes/search | Search notes |
| POST | /notes/notes | Create a note |
| POST | /notes/notes/update | Update a note |
| POST | /notes/notes/move | Move a note |
| POST | /notes/notes/delete | Delete a note |
| POST | /notes/show | Open a note in Notes.app |

### Reminders `/reminders`

| Method | Path | Description |
|--------|------|-------------|
| GET | /reminders/lists | List reminder lists |
| GET | /reminders/reminders | List reminders |
| GET | /reminders/reminder | Get a single reminder |
| POST | /reminders/reminders | Create a reminder |
| POST | /reminders/reminders/complete | Complete reminders |
| POST | /reminders/reminders/delete | Delete reminders |

### Things 3 `/things`

| Method | Path | Description |
|--------|------|-------------|
| GET | /things/lists | List built-in lists and areas |
| GET | /things/areas | List areas |
| GET | /things/projects | List projects |
| GET | /things/todos | List todos (filter by list, area, project, status) |
| GET | /things/todo | Get a single todo |
| POST | /things/todos | Create a todo |
| POST | /things/todos/status | Set todo status (completed, open, cancelled) |
| POST | /things/todos/delete | Delete todos |

### NetNewsWire `/nnw`

| Method | Path | Description |
|--------|------|-------------|
| GET | /nnw/feeds | List feeds |
| GET | /nnw/articles | List articles |
| GET | /nnw/article | Get a single article |
| GET | /nnw/current | Get the currently selected article |
| GET | /nnw/deeplink | Get a deep link to an article |
| POST | /nnw/articles/read | Mark articles read/unread |
| POST | /nnw/articles/starred | Star/unstar articles |
| POST | /nnw/open | Open an article in NetNewsWire |

### Shortcuts `/shortcuts`

| Method | Path | Description |
|--------|------|-------------|
| GET | /shortcuts/shortcuts | List shortcuts |
| GET | /shortcuts/shortcut | Get a single shortcut |
| GET | /shortcuts/folders | List folders |
| POST | /shortcuts/run | Run a shortcut |

### Global Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | / | List all bridges with current health status |
| GET | /health | Aggregate health check (`ok` or `degraded`) |
| GET | /help | Overview of all bridges |

## Response Format

All endpoints return **markdown** by default (tables for lists, key-value pairs for single objects). To get JSON, either:

- Add `?format=json` to the URL
- Send an `Accept: application/json` header

JSON responses use `{"ok": true, "result": ...}` on success and `{"ok": false, "error": "..."}` on failure.

## Configuration

Config file: `~/.config/mac-bridge/config` (simple `key = value` format, `#` comments allowed).

```ini
# Server
port = 7330
rate-limit = 10

# Disable specific bridges entirely
disabled = messages, shortcuts

# Mail: map account names to their archive mailbox names
archive-mailboxes = Work=Archive, Personal=All Mail

# Block all POST endpoints across all bridges
read-only = true

# Block POSTs for a specific bridge only
things.read-only = true

# Deny specific endpoints (paths relative to bridge prefix)
notes.deny = notes/delete, notes/update

# Allow only specific endpoints (health/help/schema always remain accessible)
mail.allow = mailboxes, messages, message
```

Per-bridge `allow` and `deny` are mutually exclusive — if both are set, `allow` takes precedence.

### Environment Variables

Environment variables override config file values:

| Variable | Config key |
|----------|------------|
| `MACBRIDGE_PORT` | `port` |
| `MACBRIDGE_RATE_LIMIT` | `rate-limit` |
| `MACBRIDGE_DISABLED` | `disabled` |
| `MACBRIDGE_ARCHIVE_MAILBOXES` | `archive-mailboxes` |
| `MACBRIDGE_READ_ONLY` | `read-only` |

## Deployment

```bash
swift build -c release
./scripts/install.sh      # install and start as LaunchAgent
./scripts/start.sh        # start or restart
./scripts/stop.sh         # stop
./scripts/uninstall.sh    # stop and remove
```

### Logs

```bash
log stream --predicate 'subsystem == "com.user.mac-bridge"' --level info
```

## App Bindings

| Bridge | How it talks to the app |
|--------|-------------------------|
| Calendar | EventKit framework |
| Contacts | Contacts (CNContact) framework |
| Mail | ScriptingBridge (SBApplication) |
| Messages | JXA via osascript |
| Notes | JXA via osascript |
| Reminders | JXA via osascript |
| Things 3 | JXA via osascript |
| NetNewsWire | JXA via osascript |
| Shortcuts | `/usr/bin/shortcuts` CLI |

Calendar and Contacts require macOS permission grants (prompted on first use). ScriptingBridge and JXA bridges require the target app to be running.
