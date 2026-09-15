# aside-whatsapp-connector

**Message your AI agent on WhatsApp.**

Text a WhatsApp number, and an [Aside](https://aside.com) agent wakes up, reads
the message, does the work, and texts you back. No tab open, no terminal window,
no cloud service in the middle. Everything runs on your Mac, on loopback.

```
you (or anyone in a group)
        |
        v
   WhatsApp  ->  Go bridge  ->  messages.db  ->  notifier  ->  Chrome extension
                                                                     |
                                                          notification (grouped)
                                                                     |
                                                                     v
                                                          Aside event routine
                                                                     |
                                            reads full messages back via MCP,
                                            does the work, replies in the chat
```

It is four small always-on processes and one unpacked Chrome extension. The
heavy lifting (the actual WhatsApp connection) is done by the excellent
[`verygoodplugins/whatsapp-mcp`](https://github.com/verygoodplugins/whatsapp-mcp),
which this project installs, configures, supervises and wires into Aside.

---

## Why it exists

Aside can already be driven from Slack, Telegram and Discord. It cannot be
driven from WhatsApp, and there is no plugin seam to add a channel: the platform
enum is closed.

But Aside *does* capture browser notifications as inbox events, and those events
can wake a routine. So the trick is to stop trying to add a channel and instead
make a WhatsApp message produce a local browser notification. That is the whole
idea. Everything in this repo is plumbing around it.

The upside of coming in through notifications rather than a channel is that the
routine is a full Aside agent with all of your tools, memory and skills, not a
restricted chat surface.

## What you get

- **Any WhatsApp message to the bot wakes an agent.** DMs always. Group messages
  too, on every message, with no @-mention needed. Being added to the group is
  the opt-in; removing the bot is the opt-out.
- **Bursts are batched.** Ten messages in a row become one wake, not ten
  concurrent Aside sessions. The extension holds a chat open until it goes quiet
  for 25 seconds, then fires one grouped notification.
- **No tab, no window.** An MV3 background service worker does the polling, so
  Chrome just needs to be running.
- **Survives reboots.** Four LaunchAgents start at login. Pairing persists, so
  there is no QR code to rescan.
- **Tells you when it breaks.** A monitor checks the bridge and notifier every
  60 seconds and raises a macOS notification on failure, once per problem.
- **The agent can reply.** It has the full WhatsApp MCP toolset: send messages,
  react, mark read, send files and audio, download media.

## Requirements

- macOS (this uses launchd and Chrome notifications)
- [Aside](https://aside.com)
- Google Chrome
- Go 1.24+ (`brew install go`) and [uv](https://docs.astral.sh/uv/)
  (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- **A second phone number for the bot.** Do not use your personal WhatsApp
  account: the agent will be reading and replying as whoever it is paired to. A
  prepaid SIM is enough. There is no data plan needed, since the number only has
  to receive one SMS and then stay alive, so look for pay-as-you-go credit
  (roughly $15/year) rather than a monthly plan.
- One free linked-device slot on that WhatsApp account (you get four)

## Install

```bash
git clone https://github.com/<you>/aside-whatsapp-connector.git
cd aside-whatsapp-connector

scripts/install.sh     # clone + build + generate config and LaunchAgents
scripts/pair.sh        # scan the QR with the bot's phone (read the warnings)
scripts/start.sh       # load all four LaunchAgents
scripts/doctor.sh      # verify every hop
```

Then three manual steps that no script can do for you: load `extension/` in
Chrome, register the MCP server in Aside, and create the event routine.
[`docs/SETUP.md`](docs/SETUP.md) walks through all of it.

**Handing this to a coding agent instead?** Point it at
[`AGENTS.md`](AGENTS.md). It covers what an agent can and cannot do here, the
sandbox constraints, and the failure modes specific to automated setup.

## Everyday commands

| | |
| --- | --- |
| `scripts/doctor.sh` | Check every hop. Start here when something breaks. |
| `scripts/doctor.sh --json` | Same, machine-readable. |
| `scripts/stop.sh` / `start.sh` | Stop and start everything. Pairing survives. |
| `scripts/pair.sh` | Re-pair after a logout. Stop the stack first. |
| `scripts/uninstall.sh` | Remove agents and config, keep the pairing. |
| `scripts/uninstall.sh --purge` | Also delete the paired session. |

Logs are in `~/Library/Logs/aside-whatsapp/`.

## Layout

```
notifier/server.py        stdlib-only HTTP service; reads the bridge DB read-only
notifier/index.html       optional debug page, shows what the notifier sees
extension/                MV3 extension: polls, batches, fires notifications
scripts/install.sh        build + generate everything
scripts/doctor.sh         per-hop health check
scripts/{pair,start,stop,uninstall}.sh
aside/routine-prompt.md   the event routine prompt, with placeholders
aside/mcp-server.json     the MCP server registration shape
docs/SETUP.md             full walkthrough
docs/TROUBLESHOOTING.md   every failure we actually hit, with fixes
docs/ARCHITECTURE.md      why it is built this way
AGENTS.md                 instructions for AI agents doing the setup
```

## Security, in short

Read [`docs/SECURITY.md`](docs/SECURITY.md) before you point this at a group.

The short version: **an agent with your credentials is reading text that other
people wrote.** That is a prompt-injection path by construction. The shipped
routine prompt scopes it (owner number is authoritative, everyone else gets
read-only help, message content is data and never instructions) but the scoping
is a prompt, not a sandbox. Give the routine the narrowest permissions that still
do the job, and treat `whatsapp-bridge/store/` as a credential.

Nothing here listens on anything but `127.0.0.1`. The bridge's REST API requires
a bearer token generated at first run. The notifier is read-only on the database
and exposes no write path at all.

## Credits

The hard part, the WhatsApp connection itself, is
[`verygoodplugins/whatsapp-mcp`](https://github.com/verygoodplugins/whatsapp-mcp),
built on [whatsmeow](https://github.com/tulir/whatsmeow). This repo is the glue
that turns it into an agent inbox.

This is an unofficial integration. It drives a normal consumer WhatsApp account
as a linked device, and it is not affiliated with or endorsed by WhatsApp or
Meta. Automating a consumer account carries a real risk of that account being
banned. Use a number you can afford to lose.

## License

MIT
