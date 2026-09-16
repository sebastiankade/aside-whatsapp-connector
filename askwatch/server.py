#!/usr/bin/env python3
"""
askwatch - tell me on WhatsApp when an Aside session is waiting on me.

The problem it solves: Aside sessions running on a headless/worker machine
suspend on ask_user_question (and on action confirmations) and then sit there
silently. You only find out by screen-sharing into the box.

How it works, and why this way:

  Aside stores a suspended session's pending question on disk, in the account
  state DB:

      sessions.status    = 'suspended'
      sessions.suspension = {"kind":"ask-user-question",
                             "toolCallId":"toolu_...",
                             "request":{"questions":[{"header":..,"question":..,
                                                      "options":[..]}]}}

  resolveSuspension() stamps `resolvedAt` onto that same blob, so
  "waiting on a human" is exactly:

      status = 'suspended' AND suspension.resolvedAt IS NULL

  That is a plain read-only SQLite query. No daemon auth, no tRPC, no polling
  of the model. We read it, and push a WhatsApp DM through the bridge that is
  already running for the connector.

This is one-way on purpose. It notifies; it does not answer. Answering means
calling the daemon's sessions.resolveSuspension, which needs a signed daemon
token and opens a remote-approval path into a full-access agent. Deliberately
out of scope here.

Environment:
  ASKWATCH_STATE_DB       path to Aside's account state.db          (required)
  ASKWATCH_RECIPIENT      WhatsApp JID or bare number to DM         (required)
  ASKWATCH_BRIDGE_URL     bridge REST base    (default http://127.0.0.1:8080/api)
  ASKWATCH_TOKEN_FILE     bridge bearer token (default <store>/.bridge-token)
  ASKWATCH_SEEN_FILE      dedupe state        (default alongside this script)
  ASKWATCH_INTERVAL       seconds between polls                  (default 20)
  ASKWATCH_MACHINE        label used in the message            (default hostname)
  ASKWATCH_KINDS          comma list of suspension kinds to report
                          (default ask-user-question,action-confirmation,approval)
  ASKWATCH_REMIND_AFTER   re-nag after N seconds still unanswered; 0 = never
                                                                  (default 0)
"""

import json
import os
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def _require(name, hint):
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit("askwatch: {} is not set.\n  e.g. export {}={}".format(name, name, hint))
    return os.path.expanduser(value)


STATE_DB = _require("ASKWATCH_STATE_DB", "~/.aside/u/0/state.db")
RECIPIENT = _require("ASKWATCH_RECIPIENT", "<your-number-in-international-format>")
BRIDGE_URL = os.environ.get("ASKWATCH_BRIDGE_URL", "http://127.0.0.1:8080/api").rstrip("/")
SEEN_FILE = os.path.expanduser(
    os.environ.get("ASKWATCH_SEEN_FILE", os.path.join(HERE, ".askwatch-seen.json"))
)
INTERVAL = max(5, int(os.environ.get("ASKWATCH_INTERVAL", "20")))
MACHINE = os.environ.get("ASKWATCH_MACHINE", "").strip() or socket.gethostname().split(".")[0]
REMIND_AFTER = int(os.environ.get("ASKWATCH_REMIND_AFTER", "0"))
KINDS = tuple(
    k.strip()
    for k in os.environ.get(
        "ASKWATCH_KINDS", "ask-user-question,action-confirmation,approval"
    ).split(",")
    if k.strip()
)

_default_token_file = os.path.join(
    os.environ.get("ASIDE_WA_STORE_DIR", ""), ".bridge-token"
)
TOKEN_FILE = os.path.expanduser(
    os.environ.get("ASKWATCH_TOKEN_FILE", _default_token_file)
)

STATE_DB_URI = "file:{}?mode=ro".format(STATE_DB)

# Kept deliberately short. A WhatsApp DM is a nudge, not the transcript.
MAX_QUESTION_CHARS = 400
MAX_OPTIONS = 6

KIND_LABEL = {
    "ask-user-question": "question",
    "action-confirmation": "confirmation",
    "approval": "permission",
}


def log(message):
    print("[askwatch] {}".format(message), flush=True)


def read_token():
    try:
        with open(TOKEN_FILE, "r") as handle:
            return handle.read().strip()
    except OSError as exc:
        log("cannot read bridge token at {}: {}".format(TOKEN_FILE, exc))
        return ""


def load_seen():
    try:
        with open(SEEN_FILE, "r") as handle:
            data = json.load(handle)
        if isinstance(data, dict) and isinstance(data.get("sent"), dict):
            return data["sent"], bool(data.get("initialised"))
    except (OSError, ValueError):
        pass
    return {}, False


def save_seen(sent, initialised=True):
    tmp = SEEN_FILE + ".tmp"
    try:
        with open(tmp, "w") as handle:
            json.dump({"initialised": initialised, "sent": sent}, handle)
        os.replace(tmp, SEEN_FILE)
    except OSError as exc:
        log("could not persist seen-state: {}".format(exc))


def fetch_pending():
    """Sessions currently blocked on a human. Read-only; never writes."""
    try:
        conn = sqlite3.connect(STATE_DB_URI, uri=True, timeout=5)
    except sqlite3.Error as exc:
        log("cannot open state db {}: {}".format(STATE_DB, exc))
        return None

    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT id,
                   title,
                   updated_at,
                   suspension
              FROM sessions
             WHERE status = 'suspended'
               AND suspension IS NOT NULL
               AND json_extract(suspension, '$.resolvedAt') IS NULL
               AND json_extract(suspension, '$.error') IS NULL
            """
        ).fetchall()
    except sqlite3.Error as exc:
        # A schema change upstream should degrade to silence, not a crash loop.
        log("query failed (Aside schema may have changed): {}".format(exc))
        return None
    finally:
        conn.close()

    pending = []
    for row in rows:
        try:
            suspension = json.loads(row["suspension"])
        except (TypeError, ValueError):
            continue
        kind = suspension.get("kind")
        tool_call_id = suspension.get("toolCallId")
        if not tool_call_id or kind not in KINDS:
            continue
        pending.append(
            {
                "session_id": row["id"],
                "title": (row["title"] or "").strip() or "(untitled task)",
                "updated_at": row["updated_at"],
                "kind": kind,
                "tool_call_id": tool_call_id,
                "request": suspension.get("request") or {},
            }
        )
    return pending


def clip(text, limit):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "\u2026"


def compose(item, reminder=False):
    kind = item["kind"]
    request = item["request"]
    lines = []

    prefix = "Still waiting" if reminder else "Aside needs you"
    lines.append("*{}* \u2014 {} on `{}`".format(prefix, KIND_LABEL.get(kind, kind), MACHINE))
    lines.append("")

    if kind == "ask-user-question":
        questions = request.get("questions") or []
        for question in questions[:2]:
            header = clip(question.get("header", ""), 60)
            if header:
                lines.append("*{}*".format(header))
            lines.append(clip(question.get("question", ""), MAX_QUESTION_CHARS))
            options = [
                clip(opt.get("label", ""), 40)
                for opt in (question.get("options") or [])
                if opt.get("label")
            ]
            if options:
                shown = options[:MAX_OPTIONS]
                more = len(options) - len(shown)
                rendered = " / ".join(shown) + ("  (+{} more)".format(more) if more else "")
                lines.append("_Options:_ {}".format(rendered))
            lines.append("")
        if len(questions) > 2:
            lines.append("_(+{} more questions)_".format(len(questions) - 2))
    else:
        title = clip(request.get("title", ""), 80)
        if title:
            lines.append("*{}*".format(title))
        lines.append(clip(request.get("message", ""), MAX_QUESTION_CHARS))
        lines.append("")

    lines.append("Task: {}".format(clip(item["title"], 80)))
    lines.append("Session: {}".format(item["session_id"]))
    lines.append("")
    lines.append("_Answer it in Aside on {} \u2014 I can't answer from here._".format(MACHINE))

    return "\n".join(line for line in lines).strip()


def send(text, token):
    payload = json.dumps({"recipient": RECIPIENT, "message": text}).encode("utf-8")
    request = urllib.request.Request(
        BRIDGE_URL + "/send",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer {}".format(token),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = json.loads(response.read().decode("utf-8") or "{}")
            if body.get("success") is False:
                log("bridge refused the send: {}".format(body.get("message")))
                return False
            return True
    except urllib.error.HTTPError as exc:
        log("bridge HTTP {}: {}".format(exc.code, exc.read()[:200]))
    except Exception as exc:  # noqa: BLE001 - a notifier must never die on a send
        log("send failed: {}".format(exc))
    return False


def main():
    log(
        "watching {} every {}s -> {} (kinds: {})".format(
            STATE_DB, INTERVAL, RECIPIENT, ", ".join(KINDS)
        )
    )

    sent, initialised = load_seen()

    while True:
        pending = fetch_pending()

        if pending is None:
            time.sleep(INTERVAL)
            continue

        # First ever run: adopt whatever is already pending as "known".
        # Without this, a fresh install blasts every stale suspension ever
        # abandoned in this account. Same lesson as the extension cursor.
        if not initialised:
            sent = {item["tool_call_id"]: time.time() for item in pending}
            initialised = True
            save_seen(sent, True)
            log("first run: adopted {} existing pending item(s), staying quiet".format(len(pending)))
            time.sleep(INTERVAL)
            continue

        live = set()
        changed = False
        now = time.time()

        for item in pending:
            key = item["tool_call_id"]
            live.add(key)
            last = sent.get(key)

            if last is None:
                if send(compose(item), read_token()):
                    sent[key] = now
                    changed = True
                    log("notified: {} ({})".format(item["session_id"], item["kind"]))
                continue

            if REMIND_AFTER > 0 and now - last >= REMIND_AFTER:
                if send(compose(item, reminder=True), read_token()):
                    sent[key] = now
                    changed = True

        # Drop answered items so the file cannot grow forever.
        for key in list(sent):
            if key not in live:
                del sent[key]
                changed = True

        if changed:
            save_seen(sent, True)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
