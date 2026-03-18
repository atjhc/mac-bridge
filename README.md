# MacBridge

Local HTTP API for macOS apps. A single server exposes REST endpoints for Calendar, Contacts, Mail, Messages, Notes, Reminders, Things 3, NetNewsWire, and Shortcuts.

Requires macOS 14+.

## Quick Start

```bash
# 1. Build
swift build -c release

# 2. Install and start as LaunchAgent
./scripts/install.sh

# 3. (Optional) Install Notes shortcuts for checklists, markdown, tags, tables, and pinning
./scripts/install-shortcuts.sh
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
| POST | /calendar/events/update | Update an event |
| POST | /calendar/events/recurrence | Set recurrence rule |
| POST | /calendar/events/recurrence/remove | Remove recurrence |
| POST | /calendar/events/alarm | Add an alarm |
| POST | /calendar/events/alarm/remove | Remove all alarms |
| POST | /calendar/events/delete | Delete events |

### Contacts `/contacts`

| Method | Path | Description |
|--------|------|-------------|
| GET | /contacts/contacts | List contacts |
| GET | /contacts/contact | Get a single contact |
| GET | /contacts/search | Search contacts |
| POST | /contacts/contacts | Create a contact |
| POST | /contacts/contacts/update | Update a contact |
| POST | /contacts/contacts/delete | Delete contacts |

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
| POST | /mail/compose | Compose a draft |
| POST | /mail/compose/update | Update a draft |
| POST | /mail/reply | Reply to a message (creates draft) |
| POST | /mail/forward | Forward a message (creates draft) |
| POST | /mail/send | Send a draft |

### Messages `/messages`

| Method | Path | Description |
|--------|------|-------------|
| GET | /messages/chats | List chats |
| GET | /messages/chat | Get a single chat |
| GET | /messages/messages | Get message transcript for a chat |
| GET | /messages/participants | List participants |
| POST | /messages/send | Send a message |

### Notes `/notes`

| Method | Path | Description |
|--------|------|-------------|
| GET | /notes/accounts | List accounts |
| GET | /notes/folders | List folders |
| POST | /notes/folders | Create a folder |
| GET | /notes/notes | List notes |
| GET | /notes/note | Get a single note |
| GET | /notes/search | Search notes |
| POST | /notes/notes | Create a note (HTML body) |
| POST | /notes/notes/create-markdown | Create a note from Markdown |
| POST | /notes/notes/append-markdown | Append Markdown to a note |
| POST | /notes/notes/update | Update a note |
| POST | /notes/notes/move | Move notes |
| POST | /notes/notes/delete | Delete notes |
| POST | /notes/checklist | Add a checklist item (tappable checkbox) |
| POST | /notes/tags/add | Add tags to a note |
| POST | /notes/tags/remove | Remove tags from a note |
| POST | /notes/table | Add a table from CSV |
| POST | /notes/pin | Pin a note |
| POST | /notes/unpin | Unpin a note |
| POST | /notes/show | Open a note in Notes.app |

Endpoints marked with shortcuts require the one-time shortcut installation (see below).

### Reminders `/reminders`

| Method | Path | Description |
|--------|------|-------------|
| GET | /reminders/lists | List reminder lists |
| GET | /reminders/reminders | List reminders |
| GET | /reminders/reminder | Get a single reminder |
| POST | /reminders/reminders | Create a reminder |
| POST | /reminders/reminders/update | Update a reminder |
| POST | /reminders/reminders/complete | Complete reminders |
| POST | /reminders/reminders/delete | Delete reminders |
| POST | /reminders/lists | Create a list |
| POST | /reminders/lists/delete | Delete a list |

### Things 3 `/things`

| Method | Path | Description |
|--------|------|-------------|
| GET | /things/lists | List built-in lists and areas |
| GET | /things/areas | List areas |
| GET | /things/projects | List projects |
| GET | /things/todos | List todos (filter by list, area, project, status) |
| GET | /things/todo | Get a single todo |
| POST | /things/todos | Create a todo |
| POST | /things/todos/update | Update a todo |
| POST | /things/todos/status | Set todo status (completed, open, cancelled) |
| POST | /things/todos/delete | Delete todos |
| POST | /things/projects | Create a project |
| POST | /things/headings | Create a heading in a project |

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

## Installation

### 1. Build and install the server

```bash
swift build -c release
./scripts/install.sh      # install and start as LaunchAgent
```

### 2. Grant permissions

On first launch, macOS will prompt for Calendar and Contacts access. Approve these in System Settings > Privacy & Security.

For message history (`GET /messages/messages`), the MacBridge process needs Full Disk Access (reads `~/Library/Messages/chat.db`).

### 3. Install Notes shortcuts (optional)

Notes checklist, markdown, tag, table, and pin endpoints use Apple Shortcuts under the hood. A one-time setup installs 8 shortcuts into your Shortcuts library:

```bash
./scripts/install-shortcuts.sh
```

This opens each shortcut file and waits for you to click **Add Shortcut** in the dialog (8 clicks total). On first use, Shortcuts may also prompt for permission to access Notes — choose **Always Allow**.

If you skip this step, all other Notes endpoints still work. Only the Shortcuts-powered endpoints (`create-markdown`, `append-markdown`, `checklist`, `tags/*`, `table`, `pin`, `unpin`) will return errors.

### 4. Code signing (optional, for SSH deployment)

To preserve TCC permissions across rebuilds:

```bash
./scripts/build.sh    # build, sign with "Heimdall" identity, restart service
```

## Management

```bash
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
| Mail | ScriptingBridge + AppleScript |
| Messages | JXA + SQLite (chat.db for transcripts) |
| Notes | JXA + Apple Shortcuts (for checklists, markdown, tags, tables, pinning) |
| Reminders | JXA via osascript |
| Things 3 | JXA + AppleScript + URL scheme |
| NetNewsWire | JXA via osascript |
| Shortcuts | `/usr/bin/shortcuts` CLI |

Calendar and Contacts require macOS permission grants (prompted on first use). Messages transcript requires Full Disk Access. JXA/ScriptingBridge bridges auto-launch their target app if not running.
