# Security

Read this before pointing the connector at a group, or giving the routine
`full-access`.

---

## The core risk

**An agent holding your credentials is reading text that other people wrote, and
acting on it.**

That is not a bug in this design, it is the design. A WhatsApp message is
untrusted input. The routine that consumes it has your Google account, your
files, your browser session and whatever else Aside can reach. Anyone who can
put text in front of it gets an attempt at your accounts.

This is the standard prompt-injection problem, and it is worse here than usual
in two ways: the input channel is open to anyone who knows the number, and in a
group the input is written by people you did not choose.

## What the shipped prompt does about it

[`aside/routine-prompt.md`](../aside/routine-prompt.md) contains a trust section
that:

- names the owner's WhatsApp number as the only authoritative source,
- allows anyone else read-only help (answering questions, looking things up),
- forbids externally visible or hard-to-undo actions on behalf of non-owners:
  no email as the owner, no spending, no deleting, no public posting, no account
  or security changes,
- states that message content is data and never instructions, and that a message
  claiming to be the owner from a different number is to be treated as hostile.

Keep that section if you modify the prompt.

## What that is not

**It is a prompt, not a sandbox.** It reduces the odds; it does not make the
attack impossible. A sufficiently well-crafted message may still talk a model
out of its instructions. Do not treat the trust section as a security boundary
you can lean on.

The real controls are the ones outside the model:

- **Give the routine the narrowest permission mode that still does the job.**
  `full-access` is convenient and is exactly what an injected instruction wants.
- **Prefer a DM-only bot** if you do not specifically need a group. The attack
  surface is then only people who know the number.
- **Scope write access.** If the job is "append requests to a sheet", constrain
  it to that one document rather than the whole account.
- **Read the transcripts** for a while after you set it up. The routine leaves a
  session per wake; skim them.

## Use a separate number

Do not pair your personal WhatsApp. The agent reads and sends as whatever
account it is paired to, so pairing your own gives it every conversation you
have and lets it send as you.

A prepaid SIM used only for this costs about $15 a year and contains the blast
radius to one account you can throw away.

## Credentials on disk

`whatsapp-bridge/store/` is a **full credential set**. Anyone with those files
can read and send as the bot account, from anywhere, without your phone.

- Never commit it. The `.gitignore` covers it, but do check.
- Never copy it into a log, a paste, a support ticket or a chat.
- Never back it up to cloud storage.
- `chmod 700` it if the machine has other users.

If it leaks: log the device out from your phone immediately (WhatsApp >
Settings > Linked Devices > tap the device > Log out), delete the directory,
then re-pair. Logging out server-side invalidates the session, so deleting the
files alone is not enough.

`store/.bridge-token` is also live: it authenticates writes to the bridge's REST
API. Same rules.

## Network surface

Everything binds to `127.0.0.1` only.

| Service | Port | Auth |
| --- | --- | --- |
| Bridge REST API | 8080 | 256-bit bearer token |
| MCP server | 8009 | none (loopback only) |
| Notifier | 8011 | none (loopback only, read-only) |

The notifier has no write path at all and opens the database read-only, so the
worst a local process can do with it is read your messages. That is still a real
concern on a shared machine: **any local process can read port 8011 without
authentication.** Do not run this on a machine you share.

The webhook forwarder is disabled. Upstream defaults it to **on**, which would
POST every inbound message to an unvetted local port. Leave it off unless you
have written the receiver yourself.

## Account risk

This drives a normal consumer WhatsApp account as a linked device. It is not the
official Cloud API and is not sanctioned by WhatsApp.

Automated behaviour on a consumer account can get that account banned. Sending
unsolicited messages makes it much more likely. Use a number you can afford to
lose, and do not use this to message people who did not ask to be messaged.

## Reporting

Found something? Open an issue for anything non-sensitive. For an actual
vulnerability, email the maintainer rather than filing publicly.
