# askwatch

Get a WhatsApp DM when an Aside session on this machine is blocked waiting on
you, so you do not have to screen-share into the box to find out.

One-way by design. It tells you a question is waiting. It does not let you
answer from WhatsApp. See [Why it does not answer](#why-it-does-not-answer).

---

## What it watches

Aside writes a suspended session's pending prompt straight to the account
state DB at `~/.aside/u/<account>/state.db`:

```
sessions.status     = 'suspended'
sessions.suspension = {"kind":"ask-user-question",
                       "toolCallId":"toolu_...",
                       "request":{"questions":[{"header":.., "question":..,
                                                "options":[..]}]}}
```

When a suspension is answered, the daemon stamps `resolvedAt` onto that same
blob. When a run is interrupted or aborted, it stamps `error`. So "actually
waiting on a human right now" is one read-only query:

```sql
SELECT id, title, suspension FROM sessions
 WHERE status = 'suspended'
   AND json_extract(suspension, '$.resolvedAt') IS NULL
   AND json_extract(suspension, '$.error')      IS NULL
```

Three suspension kinds exist, all reported by default:

| kind | raised by |
|---|---|
| `ask-user-question` | the agent asking you something |
| `action-confirmation` | final-confirm before a send/purchase/delete |
| `approval` | a permission prompt |

Narrow it with `ASKWATCH_KINDS` if you only care about one.

## What it does not touch

Opens the state DB `mode=ro` and never writes to it. Its only side effect is
an outbound WhatsApp message through the bridge that is already running for
the connector. It adds no WhatsApp connection and no linked-device slot.

## Install on the worker

Assumes the connector is already installed and paired on this machine.

1. Append to `~/Library/Application Support/aside-whatsapp/env.sh`:

   ```sh
   export ASKWATCH_STATE_DB='/Users/YOU/.aside/u/0/state.db'
   export ASKWATCH_RECIPIENT='<your-number>'         # international format, no +
   export ASKWATCH_BRIDGE_URL='http://127.0.0.1:8080/api'
   export ASKWATCH_TOKEN_FILE="$ASIDE_WA_STORE_DIR/.bridge-token"
   export ASKWATCH_SEEN_FILE="$ASIDE_WA_STATE_DIR/askwatch-seen.json"
   export ASKWATCH_MACHINE='worker'                 # appears in the message
   export ASKWATCH_INTERVAL='20'
   export ASKWATCH_REMIND_AFTER='0'                 # 0 = never re-nag
   ```

   Check the account number in `ASKWATCH_STATE_DB`. `u/0` is the first
   account; a second Aside account is `u/1`, and it has its own state DB.

   `ASKWATCH_RECIPIENT` is the phone you **read**, which is usually not the
   number the bridge is logged in as. If the worker is paired to its own
   line the two differ, and setting this to the bridge's own number sends
   every alert into that account's "Message Yourself" chat, where you will
   never see it. This fails silently in the worst way: the bridge returns
   success and the message really is delivered, just to the wrong place. Do
   not read it out of `whatsmeow_device`; use the number on the handset in
   your pocket.

2. Install the launcher and LaunchAgent:

   ```sh
   cp askwatch/run-askwatch.sh "$HOME/Library/Application Support/aside-whatsapp/"
   chmod +x "$HOME/Library/Application Support/aside-whatsapp/run-askwatch.sh"

   source "$HOME/Library/Application Support/aside-whatsapp/env.sh"

   sed -e "s|__HOME__|$HOME|g" -e "s|__REPO__|$ASIDE_WA_REPO|g" \
     askwatch/com.aside-whatsapp.askwatch.plist \
     > "$HOME/Library/LaunchAgents/com.aside-whatsapp.askwatch.plist"

   xattr -dr com.apple.quarantine \
     "$HOME/Library/LaunchAgents/com.aside-whatsapp.askwatch.plist" \
     "$HOME/Library/Application Support/aside-whatsapp/run-askwatch.sh" \
     askwatch/server.py

   launchctl bootstrap gui/$(id -u) \
     "$HOME/Library/LaunchAgents/com.aside-whatsapp.askwatch.plist"
   ```

   Strip quarantine on every file the agent wrote, including the plist.
   A quarantined file runs fine from a terminal and is refused by launchd.
   Ignore whatever `bootstrap` prints; verify with `launchctl print` instead.

   `WorkingDirectory` has to be a directory that exists or launchd refuses
   the job before the wrapper ever runs, which is why it is templated from
   `ASIDE_WA_REPO` instead of assuming the repo sits in `~/Dev`.

   Run these in a real terminal. `bootstrap`, `bootout` and `kickstart` all
   fail from inside an Aside session, which can read the launchd domain but
   not modify it.

3. Verify:

   ```sh
   launchctl print gui/$(id -u)/com.aside-whatsapp.askwatch | head -20
   tail -f ~/Library/Logs/aside-whatsapp/askwatch.out.log
   ```

   Expect `first run: adopted N existing pending item(s), staying quiet`.

## First run is deliberately silent

Any account that has been used for a while has a pile of stale suspensions
nobody ever answered (this account had 22). Alerting on those on first boot
would be useless noise, so the first poll adopts everything already pending
as known and says nothing. Only suspensions that appear *after* that produce
a message.

Delete `ASKWATCH_SEEN_FILE` to reset that cursor. The next poll will re-adopt
silently, not replay.

## Dry run before trusting it

Renders what it would send, sends nothing:

```sh
source "$HOME/Library/Application Support/aside-whatsapp/env.sh"
python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("askwatch", "askwatch/server.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for item in m.fetch_pending():
    print("=" * 58); print(m.compose(item))
PY
```

## Why it does not answer

Answering a suspension from outside Aside is possible. The daemon exposes
`sessions.resolveSuspension({accountId, sessionId, toolCallId, response})`
over tRPC on `127.0.0.1:21420`, and it resumes the *existing* run in place
rather than starting a new turn, so the original `ask_user_question` call
returns your answer and the agent continues mid-task.

Two reasons it is out of scope here:

- It needs a signed daemon token. The endpoint rejects unauthenticated
  loopback calls.
- `resolveSuspension` also answers `action-confirmation`. The WhatsApp worker
  routine runs at `full-access`, and group membership is the connector's
  entire access-control model. A reply path means whoever can get a message
  into the watched chat can approve a full-access action remotely. Today a
  confirmation prompt is a hard stop only you can clear at the machine, and
  that is a real safety property worth keeping.

If you do build the reply path later: bind it to your personal DM JID only,
never a group; correlate replies by WhatsApp's quoted-message id rather than
by ordering; and consider refusing to relay `action-confirmation` entirely.

## Troubleshooting

| symptom | cause |
|---|---|
| `cannot open state db` | wrong account number, or path not expanded |
| `bridge HTTP 401` | `ASKWATCH_TOKEN_FILE` wrong, or bridge regenerated its token |
| `Bootstrap failed: 5: Input/output error` | `WorkingDirectory` does not exist, or you ran `launchctl` from inside an Aside session instead of a terminal |
| sends succeed but nothing arrives | `ASKWATCH_RECIPIENT` is the bridge's own number; alerts are sitting in its Message Yourself chat |
| startup line shows a stale recipient/interval | env edits are read once at startup; `bootout` + `bootstrap` to apply them |
| `query failed (Aside schema may have changed)` | Aside update moved the suspension shape; the watcher stays quiet rather than crash-looping |
| nothing arrives, no errors | still on the first-run adoption poll, or nothing is actually suspended |
| every stale question arrives at once | seen-file was deleted *and* the process restarted mid-write; safe to ignore once |
