# Troubleshooting

Everything here was hit for real while building this. Symptom first, because
that is what you have.

**Start with `scripts/doctor.sh`.** It walks the data path in order and the first
failure is the real one.

```
WhatsApp -> bridge -> messages.db -> notifier -> extension -> Aside inbox -> routine
```

Five different problems all present as "my agent didn't wake up". Find the hop
before you start fixing.

---

## Pairing

### The phone says "Check your internet connection and try again"

Your internet is fine. Something about the Noise handshake fails over some WiFi
setups (a VPN client or a small-MTU tunnel interface are both plausible
culprits, neither confirmed).

**Fix:** turn WiFi off on the phone and scan over mobile data. This works
reliably. Turn WiFi back on afterwards; it only matters during the handshake.

### "Can't link new devices right now, try again later"

The QR payload has expired. WhatsApp rotates it roughly every 20 seconds.

**Fix:** Ctrl-C and re-run `scripts/pair.sh`. The message does not mean a
cooldown or a rate limit. Also make sure you are scanning the live terminal, not
a screenshot of it.

### The QR renders but will not scan

The bridge draws it with half-block characters, which inverts on dark terminal
themes. It also line-wraps into noise in a narrow window.

**Fix:** switch the terminal to a light theme and make the window wide, then
re-run. Counterintuitive but confirmed: light background, not dark.

The QR is printed exactly once per launch and never redrawn, so restarting the
bridge is the only way to get a fresh one. There is no phone-number pairing
fallback in this bridge.

### Pairing seems to work but the phone reports it failed

There is an open upstream bug in this area: WhatsApp sends a
`companion_reg_refresh` notification after the QR is scanned but before pairing
completes, which retires the secret the QR advertised. It affects both whatsmeow
and Baileys, so it is a WhatsApp-side change, not a library bug.

**Fix:** retry. It is intermittent. Mobile data (above) makes it much less
frequent. If it persists across several attempts, wait an hour and try again.

### `creds.registered: false` after pairing

Not a problem. That flag belongs to the phone-number pairing flow, not the QR
flow, and stays `false` for QR pairs forever.

**Check instead:** `curl -s http://127.0.0.1:8011/api/health` and look for a
non-empty `selfIds`. If that has your number in it, you are paired.

---

## The bridge

### `connectionReplaced`, or status 440, in a loop

Two processes are connected to the same WhatsApp account and displacing each
other. Almost always an orphaned instance from an earlier manual run.

**Fix:**

```bash
lsof -nP -iTCP:8080
scripts/stop.sh
kill -9 <any stray pid>
scripts/start.sh
```

If you cannot find the process, log the device out from your phone (WhatsApp >
Linked Devices > tap the device > Log out). The orphan will exit on its own with
a 401. Then re-pair.

**Never start the bridge with `&` or `nohup`.** You will not be able to stop it
cleanly later, and this is exactly how the 440 loop happens.

### "Apple could not verify..." dialog at login

The binary or a plist carries `com.apple.quarantine`. It runs fine from a
terminal and Gatekeeper blocks it under launchd, so this only shows up at the
next login, long after whatever caused it.

Click **Done**. Never click **Move to Bin**, which deletes the bridge binary.

**Fix:**

```bash
xattr -dr com.apple.quarantine ~/Dev/whatsapp-mcp \
  "$HOME/Library/Application Support/aside-whatsapp" \
  ~/Dev/aside-whatsapp-connector
xattr -d com.apple.quarantine ~/Library/LaunchAgents/com.aside-whatsapp.*.plist
```

`install.sh` does this, but **rebuilding re-applies the flag**, and the plists
are in a separate directory that is easy to forget. `scripts/doctor.sh` checks
for it.

### `go build` fails: "library load disallowed by system policy"

Same quarantine problem, on the Go toolchain or module cache.

**Fix:** `xattr -dr com.apple.quarantine ~/go ~/sdk` then rebuild.

### Go is not installed and `brew install go` is not an option

Download the official tarball:

```bash
curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go1.25.0.darwin-arm64.tar.gz
mkdir -p ~/sdk && tar -C ~/sdk -xzf /tmp/go.tar.gz
export PATH="$HOME/sdk/go/bin:$PATH"
```

`install.sh` already looks in `~/sdk/go/bin/go`.

---

## The MCP server

### Writes return `HTTP 401 - Unauthorized`, reads look empty

Relative paths in `.env`. The launcher does `cd whatsapp-mcp-server` before
exec, so a relative path resolves one directory too deep. The bridge token is
then read from the wrong place, requests go out with an empty auth header, and
reads silently hit an empty database, which looks like "no messages" rather than
an error.

**Fix:** use absolute paths for `WHATSAPP_DB_PATH` and `WHATSMEOW_DB_PATH`.
`install.sh` always writes absolute paths, so this only bites if you hand-edit.
Restart afterwards: the paths are read at import time.

### `.env` changes have no effect

**Neither component reads `.env`.** Not the Go binary, not the Python server.
Both read plain environment variables only. Every default silently applies.

This matters most for `WEBHOOK_ENABLED`, which defaults to **true** and will
make the bridge POST every inbound message to an unvetted local port.

**Fix:** edit `~/Library/Application Support/aside-whatsapp/env.sh` instead,
which every launcher explicitly sources, then `scripts/stop.sh && scripts/start.sh`.
If you are running something by hand: `set -a; . ./.env; set +a` first.

### `Address already in use`, or a 404 with a Python traceback at `/mcp`

Something else owns the port. Port 8000 in particular is commonly taken.

**Fix:**

```bash
lsof -nP -iTCP:8009
```

Kill it, or reinstall on a different port with `scripts/install.sh --mcp-port 8010`
(and update the URL in Aside's MCP settings to match).

### `GET http://127.0.0.1:8009/mcp` returns 406

That is correct behaviour and means healthy. Streamable-HTTP requires
`Accept: application/json, text/event-stream`. Probe with a real `initialize`
POST, which is what `scripts/doctor.sh` does. `000` means down.

### `import pydantic_core` fails with "code signature invalid"

Quarantine again, on the wheels. Not a genuine limitation.

**Fix:** `xattr -dr com.apple.quarantine ~/Dev/whatsapp-mcp` and retry.

---

## launchd

### `Bootstrap failed: 5: Input/output error`

Misleading. The service usually loads anyway.

**Fix:** ignore the message and check the outcome instead.

```bash
launchctl print gui/$(id -u)/com.aside-whatsapp.bridge | head -20
lsof -nP -iTCP:8080 | grep -i listen
```

Never trust bootstrap's exit code, in either direction.

### `launchctl kickstart` says "Operation not permitted"

You are inside a sandboxed context (an AI agent's shell, typically). launchd
reads work there, writes do not.

**Fix:** run it in your own Terminal. See [AGENTS.md](../AGENTS.md).

### The monitor agent shows `state = not running`

Correct. It is a `StartInterval` job that runs every 60 seconds and exits. Only
`bridge`, `mcp` and `notifier` should be continuously running.

### A service restarts forever

`KeepAlive` restarts anything that exits, including a process that exits
cleanly. So a component that is crashing on startup looks like a restart loop.
`ThrottleInterval 10` caps it at one restart per 10 seconds.

**Fix:** read the error log for the actual failure.

```bash
tail -50 ~/Library/Logs/aside-whatsapp/bridge.err.log
tail -50 ~/Library/Logs/aside-whatsapp/mcp.err.log
tail -50 ~/Library/Logs/aside-whatsapp/notifier.err.log
```

---

## Notifications

### No notifications at all, but the notifier has the messages

Check the extension's service worker console first: `chrome://extensions` >
**service worker** on the card. You want a `wa-notifier ext: buffered ...` line
every 30 seconds.

- **`showNotification FAILED`** in the console: the `notifications` permission is
  missing from `manifest.json`. Extension service workers need it even though
  web pages do not.
- **Nothing logged at all:** the service worker is asleep and the alarm is not
  firing. Toggle the extension off and on.
- **Fetch errors:** the port in `background.js`, `manifest.json`'s
  `host_permissions` and `env.sh` disagree. All three must match.

### Notifications appear in macOS but Aside never wakes

Almost always the routine's event filter.

The filter must be:

```json
{ "source": "web-push-notification", "titleIncludes": "WhatsApp: " }
```

**Do not use `eventFilter.from`.** Aside normalises it with
`new URL(from).origin`. `chrome-extension://` is not a special scheme, so it
collapses to the literal string `"null"` and matches nothing, ever.

Also: if a session is already busy, events queue rather than drop. Give it a
moment before concluding it failed.

### Someone "improved" the extension and it stopped working

Two changes look harmless and are not:

- **`chrome.notifications.create()` instead of `self.registration.showNotification()`.**
  Aside captures the second and silently drops the first. No error, no log line.
- **Removing the `notifications` permission** on the reasoning that service
  worker notifications do not need it. True for web pages, false for extensions.
  Delivery breaks silently.

### One WhatsApp message spawns several Aside sessions

The debounce is not working. Every notification creates a **new task**, so
without batching, ten messages become ten concurrent sessions.

**Fix:** confirm `QUIET_MS` and the pending buffer logic are intact in
`background.js`, and that the extension was reloaded after any edit. Raise
`QUIET_MS` to 55000 for tighter grouping at the cost of about 30 seconds of
latency.

---

## Aside

### The MCP tools never appear

Tool discovery only fires on a UI lifecycle event, never on a settings write.
A server can sit at `enabled: true`, reachable and correct, contributing zero
tools indefinitely, and log nothing about it.

**Fix:** open Aside Settings and toggle the server **off, then on**. Ground truth
is `mcp.inventories.whatsapp.refreshedAt`, not `servers.whatsapp.enabled`. Once
it fires, tools are hot-injected into running sessions.

### The MCP config looks right but nothing works

Aside does not validate nested MCP server entries. A malformed entry is accepted
and persists silently.

**Fix:** check the transport literal is exactly `streamable-http`, not `http`.
That is the usual one. Compare against
[`aside/mcp-server.json`](../aside/mcp-server.json).

### A group is missing from `list_chats`

Groups only sync into the bridge's store once a message has been sent in them.

**Fix:** send one message in the group.

### Group @-mentions do not wake the agent

The notifier detects mentions by looking for the bot's phone number **and** its
LID in the message text, because WhatsApp writes mentions using the LID.

**Check:** `curl -s http://127.0.0.1:8011/api/health` should show both in
`selfIds`. If it is empty, the notifier cannot read `whatsapp.db`; check
`WA_NOTIFIER_SELF_DB` in `env.sh`.

Also note the mention must be a real mention inserted by the sender's app.
Typing the digits as plain text is not the same thing.

---

## Still stuck

Collect this before asking anyone:

```bash
scripts/doctor.sh --json
tail -50 ~/Library/Logs/aside-whatsapp/bridge.err.log
tail -50 ~/Library/Logs/aside-whatsapp/mcp.err.log
tail -50 ~/Library/Logs/aside-whatsapp/notifier.err.log
launchctl print gui/$(id -u)/com.aside-whatsapp.bridge | head -30
```

**Redact before sharing.** `env.sh` contains paths, and
`whatsapp-bridge/store/.bridge-token` is a live credential. Never paste the
contents of `whatsapp-bridge/store/` anywhere.
