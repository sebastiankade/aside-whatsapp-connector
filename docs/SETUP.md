# Setup

Start to finish, about 30 minutes, most of which is waiting for Go to compile.

Steps 1-4 are scripted. Steps 5-8 are manual and cannot be automated: they
involve a physical phone, Chrome's extension UI, and Aside's settings UI.

If anything fails, go to [TROUBLESHOOTING.md](TROUBLESHOOTING.md) rather than
improvising. Nearly everything that goes wrong here has gone wrong before and
has a known cause.

---

## Before you start

**Get a separate phone number for the bot.** This is the one decision worth
taking seriously, because the agent reads and sends as whatever account it is
paired to. If you pair your personal WhatsApp, the agent sees every conversation
you have.

The number needs to receive one SMS at registration, then just stay alive. It
never needs data. So the thing to buy is prepaid credit that lasts a year, not a
monthly plan; those differ by roughly 20x for identical usage here. Note that
most VoIP and virtual numbers (Twilio, Telnyx, and similar) are rejected by
consumer WhatsApp at registration, so a real SIM is the reliable path.

Register WhatsApp on that number. Modern WhatsApp supports multiple accounts in
one app (Settings > tap your profile picture > Account > Add account), so you do
not need a second phone or WhatsApp Business.

**Check your prerequisites:**

```bash
go version      # 1.24+       brew install go
uv --version    #             curl -LsSf https://astral.sh/uv/install.sh | sh
python3 -V      #             ships with macOS; xcode-select --install if missing
```

---

## 1. Install

```bash
git clone https://github.com/<you>/aside-whatsapp-connector.git
cd aside-whatsapp-connector
scripts/install.sh
```

This clones `verygoodplugins/whatsapp-mcp` to `~/Dev/whatsapp-mcp`, builds the Go
bridge (about 30 MB, takes a minute), syncs the Python server, writes config to
`~/Library/Application Support/aside-whatsapp/`, and generates four LaunchAgents.

It starts nothing. Pairing has to happen first.

Useful flags:

```
--mcp-dir PATH        put the whatsapp-mcp checkout somewhere else
--device-name NAME    the label shown in WhatsApp > Linked Devices
--bridge-port N       default 8080
--mcp-port N          default 8009
--notifier-port N     default 8011
--skip-build          reuse an existing binary and venv
```

If you change `--notifier-port` you must also edit the hardcoded URL in
`extension/manifest.json` and `extension/background.js`. Chrome requires
`host_permissions` to be a literal, so it cannot be configured at runtime.

## 2. Pair

```bash
scripts/pair.sh
```

Read what it prints. Three things decide whether this works first try:

**Use mobile data on the phone, not WiFi.** The most common failure by a
distance is the phone saying "Check your internet connection and try again"
while your internet is obviously fine. Turn WiFi off on the phone, scan over
cellular, turn it back on afterwards.

**Use a light terminal theme and a wide window.** The QR is drawn with
half-block characters. It inverts unreadably on dark themes, and it line-wraps
into noise in a narrow window.

**The QR is printed once and expires in about 20 seconds.** If it goes stale, do
not sit waiting for a refresh. Ctrl-C and run the script again.

On the phone: WhatsApp > Settings > Linked Devices > Link a Device.

When the log says it is connected, press Ctrl-C. Pairing is now stored in
`whatsapp-bridge/store/whatsapp.db` and survives restarts and reboots forever.
You should not need this script again.

## 3. Start

```bash
scripts/start.sh
```

Loads all four LaunchAgents: bridge, MCP server, notifier, monitor. They start
now and again at every login.

You will probably see `Bootstrap failed: 5: Input/output error`. **Ignore it.**
On modern macOS `launchctl bootstrap` reports failure while succeeding. The
script verifies with `launchctl print` instead of trusting the exit code, which
is why it still reports each agent as loaded.

## 4. Verify

```bash
scripts/doctor.sh
```

Every automated check should pass. It walks the data path in order, so the first
failure is the real one; fix that and re-run rather than reading the whole list.

## 5. Load the Chrome extension

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. **Load unpacked**, select the `extension/` folder in this repo
4. Click **service worker** on the extension card to open its console

Within 30 seconds you should see:

```
wa-notifier ext: initialised cursor at 1234
```

and then a `buffered ... -> cursor ...` line whenever messages arrive.

The first run deliberately starts the cursor at "now" so it does not replay your
entire message history into your agent.

Chrome may ask for notification permission. Grant it. If you never see a prompt,
check `chrome://settings/content/notifications` and make sure notifications are
not globally blocked.

## 6. Register the MCP server in Aside

In Aside's settings, add an MCP server:

```json
{
  "enabled": true,
  "transport": "streamable-http",
  "url": "http://127.0.0.1:8009/mcp",
  "auth": { "type": "none" }
}
```

Two traps here:

**The transport literal is `streamable-http`, not `http`.** Aside does not
validate nested server entries, so a wrong value is accepted silently and you
get a server that looks fine and does nothing.

**Now toggle the server off and then on.** This is not optional. Writing the
config does not trigger tool discovery; only a UI lifecycle event does. Until
you toggle it, the server sits there `enabled: true`, reachable, contributing
zero tools, and logging nothing about it.

After the toggle you should have 15 tools: `search_contacts`, `get_contact`,
`list_messages`, `list_chats`, `get_chat`, `get_direct_chat_by_contact`,
`get_contact_chats`, `get_last_interaction`, `get_message_context`,
`send_message`, `send_reaction`, `mark_messages_read`, `send_file`,
`send_audio_message`, `download_media`.

They are hot-injected into sessions that are already open, so you do not need to
restart anything.

## 7. Create the event routine

Open [`aside/routine-prompt.md`](../aside/routine-prompt.md), fill in the three
placeholders (the bot's identity, your name, your WhatsApp number), and create a
routine with:

- **Kind:** cron
- **Trigger:** event
- **Schedule:** recurring
- **Event filter:**
  ```json
  { "source": "web-push-notification", "titleIncludes": "WhatsApp: " }
  ```

Match on the title. Do not try to filter on `eventFilter.from`: Aside runs it
through `new URL(from).origin`, `chrome-extension://` is not a special scheme,
so it becomes the string `"null"` and never matches.

To find the bot's own number and LID for the prompt:

```bash
curl -s http://127.0.0.1:8011/api/health
```

The `selfIds` array holds both.

## 8. Test it

From your personal WhatsApp, message the bot number:

> what time is it in Tokyo?

Expect: a macOS notification titled `WhatsApp: <your name>` within about 30
seconds, an Aside task starting, and a reply in WhatsApp.

If the notification appears but no task starts, the break is on Aside's side, so
check the routine's event filter. If no notification appears, check the
extension's service worker console. If the service worker shows nothing arriving,
run `scripts/doctor.sh`.

---

## Tuning

Both live at the top of `extension/background.js`. Reload the extension in
`chrome://extensions` after editing.

`QUIET_MS` (default 25000) is how long a chat must be silent before its buffered
messages fire as one notification. Because polls are 30 seconds apart, anything
below 30000 effectively means "flush on the next poll that brings nothing new".
Raise it to about 55000 to require two consecutive quiet polls: tighter grouping,
roughly 30 seconds more latency.

`POLL_MINUTES` (default 0.5) is the poll interval. 30 seconds is Chrome's
minimum for MV3 alarms; setting it lower does nothing.

## Adding the bot to a group

Add the bot's number to a WhatsApp group as you would any contact. It will only
wake on messages that @-mention it or reply to something it said.

Two quirks: a group does not appear in `list_chats` until at least one message
has been sent in it, and an @-mention only registers when the sender's app
actually inserts the mention (typing the digits as plain text is not the same
thing).

Before you do this, read [SECURITY.md](SECURITY.md). Group members are not the
owner, and the routine prompt deliberately treats them differently.
