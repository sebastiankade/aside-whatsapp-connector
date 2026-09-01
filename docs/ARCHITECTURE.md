# Architecture

Why it is built this way, and what each layer is actually for. Worth reading
before you change anything, because several of the odd-looking decisions are
load-bearing.

---

## The constraint that shapes everything

Aside has native chat channels for Slack, Telegram and Discord. That list is a
closed enum in the platform's own schema, with no plugin seam. You cannot add
WhatsApp as a channel.

What Aside *does* have is an inbox that captures browser notifications as
`web-push-notification` events, and event routines that wake on them. So the
route in is not "add a channel", it is "make a WhatsApp message produce a local
browser notification".

That inversion is the whole design. Everything else is plumbing to get a message
from WhatsApp into a `showNotification()` call, and to keep the resulting agent
sessions sane.

A pleasant side effect: because the routine is a normal Aside agent rather than
a constrained chat surface, it arrives with all of your tools, memory and skills
already available.

---

## The five layers

```
  1  Go bridge (whatsmeow)      owns the ONE WhatsApp socket, writes SQLite
  2  Python MCP server          exposes WhatsApp as 15 agent tools
  3  Notifier (stdlib Python)   reads the SQLite, serves new+addressed messages
  4  Chrome extension (MV3)     polls, batches, fires grouped notifications
  5  Aside event routine        wakes, reads back via MCP, acts, replies
```

Layers 1 and 2 are [`verygoodplugins/whatsapp-mcp`](https://github.com/verygoodplugins/whatsapp-mcp)
unmodified. Layers 3-5 are this repo.

### 1. The bridge

A Go binary using [whatsmeow](https://github.com/tulir/whatsmeow). It holds the
single WhatsApp connection and exposes a REST API on `127.0.0.1:8080`, bearer-token
authenticated with a 256-bit token auto-generated at `store/.bridge-token`,
accepting loopback only.

**Only one process may ever hold a WhatsApp connection for an account.** A second
one displaces the first, and the two then fight in a `connectionReplaced` (440)
loop. This single fact drives most of the rest of the design: nothing else in
the stack opens a WhatsApp connection, and everything goes through this process.

The bridge exposes **writes only**: send, react, mark-read, download, typing,
health. There are no read endpoints. Reads happen against the SQLite database it
writes, which is why layer 3 opens the database directly rather than calling an
API.

It is compiled to a binary rather than run with `go run`, because launchd
restarts it and recompiling on every restart is both slow and a source of
flapping. CGO is required (`go-sqlite3`).

### 2. The MCP server

A Python FastMCP server on `127.0.0.1:8009/mcp`, streamable-HTTP. It proxies
writes to the bridge's REST API and reads `messages.db` directly.

Running it over HTTP rather than stdio is deliberate: **one server, many
clients**. Aside, Claude Code and Cursor can all point at the same URL. With
stdio, every client spawns its own copy, and they would all be reading the same
database and competing for the same bridge.

Upstream ships a launchd installer for the bridge but not for this, so this repo
generates that plist.

### 3. The notifier

About 190 lines of stdlib Python. No dependencies at all: nothing to install,
nothing to keep updated, no venv, works with the system `python3`.

It opens `messages.db` **read-only** (`file:...?mode=ro`) so it cannot possibly
corrupt what the bridge is writing, and serves three endpoints on
`127.0.0.1:8011`: `/api/head`, `/api/new?since=N`, `/api/health`.

Its real job is the filter, `is_addressed()`:

- **DMs always pass.** Someone messaged the bot directly; that is unambiguous.
- **Group messages only pass** when the bot is @-mentioned or someone replied to
  something the bot said. Without this, a busy group wakes an Aside session for
  every unrelated line of chatter, which is both expensive and useless.
- **`is_from_me = 0` always.** Otherwise the agent notifies itself about its own
  replies and loops forever.

Two details worth keeping:

**Self identity is read from whatsmeow's own device row, not hardcoded.** It
collects both the phone number and the LID, because WhatsApp writes an @-mention
using the LID of the person mentioned, not their number. Reading it live means
re-pairing to a different number cannot silently break mention detection.

**`/api/new` returns a `head` separate from the returned rows.** `head` is the
high-water mark of everything *examined*, including messages the filter rejected.
The client advances its cursor to `head`, so ignored group chatter is skipped
once rather than rescanned on every poll forever.

### 4. The extension

An MV3 background service worker. It exists to solve two problems.

**Removing the tab.** The first working version was a page that had to stay open.
A service worker polls on an alarm with nothing open, so Chrome just needs to be
running.

**Batching.** This is the important one. **An Aside event routine creates a new
task per notification.** Ten unbatched WhatsApp messages become ten concurrent
Aside sessions, all reading the same chat, all trying to reply. So the extension
buffers messages per chat and fires **one** notification once that chat has been
quiet for `QUIET_MS` (default 25s), with `MAX_HOLD_MS` (5 min) as a safety valve
for a chat that never goes quiet.

State lives in `chrome.storage.local`, not memory, because MV3 tears the worker
down between alarms.

Three non-obvious constraints, all verified the hard way:

- **`self.registration.showNotification()` reaches Aside's inbox.
  `chrome.notifications.create()` does not.** The second is silently dropped: no
  error, no log line. Do not switch APIs.
- **The `notifications` manifest permission is still required**, even though only
  `showNotification` is used. That intuition holds for web pages but not for
  extensions. Removing it breaks delivery silently.
- **The title prefix `WhatsApp: ` is an API.** It is what the routine's
  `titleIncludes` filter matches. The notification `tag` is set to the chat JID,
  which becomes part of Aside's `threadKey`, so a routine can be scoped to one
  specific chat without parsing message text.

The notification body doubles as the routine's instruction sheet, and always ends
with a `[rows a-b]` marker giving the exact rowid range that triggered the wake.

### 5. The routine

Wakes on the event, reads the real messages back through MCP, does the work,
optionally replies with `send_message`.

**It deliberately does not act on the notification body alone.** The body is a
truncated summary. The routine reads a wider window than `[rows a-b]` suggests,
typically the last 30 minutes of the chat, so it cannot miss a message that
arrived while it was starting.

Wakes overlap and duplicate by design, so handling is idempotent: routine memory
holds a `lastProcessedRowId`, and message ids are checked against it.

---

## Why messages are read twice

Once by the notifier, to decide whether to wake anything. Again by the routine,
through MCP, to get the real content.

This looks wasteful and is not. The notification is a **signal**, not a payload.
It has to be small enough to be a legible macOS notification, and it is subject
to truncation and grouping. The routine needs full content, media, quoted
context and history, which no notification body could carry. Separating "wake
me" from "here is everything" is what lets the notification stay a one-line
summary while the agent still gets complete context.

---

## Ports

| Port | What | Notes |
| --- | --- | --- |
| 8080 | Bridge REST API | bearer token, loopback only |
| 8009 | MCP server | 8000 is commonly taken; hence 8009 |
| 8011 | Notifier | read-only, no auth, loopback only |

All loopback. Nothing here should ever be exposed to a network.

---

## Failure behaviour

`KeepAlive` restarts anything that dies, throttled to one restart per 10 seconds
so a misconfigured bridge cannot hammer WhatsApp.

The monitor polls every 60 seconds and raises a macOS notification for: agent
not loaded, token missing or rejected, API unreachable, WhatsApp disconnected,
pairing needed, notifier down. It alerts **once per distinct problem** using
marker files in `state/`, so a long outage produces one alert rather than one
per minute, and clears the marker when the problem resolves.

The notifier being down is worth alerting on specifically, because a healthy
bridge with a dead notifier is completely silent: messages arrive, get stored,
and nothing ever wakes.

---

## Things deliberately not done

**No webhook.** The bridge can POST every inbound message to a local port, and
this is on by default upstream. It is disabled here. Aside has no inbound webhook
endpoint (`webhook` appears in its inbox source enum, but nothing local accepts
one), so the webhook would only ever point at something else you would have to
write and secure. Reading the database is simpler and has no listening surface.

**No WhatsApp Web tab.** An earlier attempt linked WhatsApp Web as the companion
device and relied on its own notifications. It does not reliably generate them
even with a valid push subscription, it burns a linked-device slot, and it needs
a tab open. The local notifier gives the same result with lower latency and no
tab.

**No Telegram relay.** WhatsApp to a relay to Aside's native Telegram channel
would give a real two-way control surface, but it adds a hop, a second bot
account, and a message-forwarding service to keep alive.

**No custom WhatsApp client.** The maintained bridge already is the
daemon-plus-MCP split you would otherwise build. Adopting it wholesale, even at
the cost of re-pairing, beat extending a bespoke scaffold.
