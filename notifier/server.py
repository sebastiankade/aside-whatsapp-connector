#!/usr/bin/env python3
"""
wa-notifier: WhatsApp -> browser notification bridge.

Reads the SQLite database that the whatsapp-mcp Go bridge already writes, and
exposes the inbound messages actually addressed to the bot: every DM, plus group
messages that @-mention the bot or reply to something the bot said.

A Chrome extension polls this service and raises one grouped notification per
chat. Aside captures those as `web-push-notification` inbox events, which wake
an event routine. The routine then reads full message content back through the
WhatsApp MCP server.

Design constraints, on purpose:
  * stdlib only. No pip install, nothing to keep updated, no venv.
  * read-only on the database, so it can never corrupt what the bridge writes.
  * bound to loopback only.

Configuration is entirely by environment variable:
  WA_NOTIFIER_DB        path to the bridge's messages.db   (required)
  WA_NOTIFIER_SELF_DB   path to whatsmeow's whatsapp.db    (default: alongside DB)
  WA_NOTIFIER_HOST      default 127.0.0.1
  WA_NOTIFIER_PORT      default 8011
"""

import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))

DB_PATH = os.environ.get("WA_NOTIFIER_DB", "")
if not DB_PATH:
    sys.exit(
        "wa-notifier: WA_NOTIFIER_DB is not set.\n"
        "Point it at the whatsapp-mcp bridge database, e.g.\n"
        "  export WA_NOTIFIER_DB=~/Dev/whatsapp-mcp/whatsapp-bridge/store/messages.db"
    )
DB_PATH = os.path.expanduser(DB_PATH)

# whatsmeow's own store, used only to learn who "we" are.
SELF_DB_PATH = os.path.expanduser(
    os.environ.get(
        "WA_NOTIFIER_SELF_DB",
        os.path.join(os.path.dirname(DB_PATH), "whatsapp.db"),
    )
)

HOST = os.environ.get("WA_NOTIFIER_HOST", "127.0.0.1")
PORT = int(os.environ.get("WA_NOTIFIER_PORT", "8011"))

# Opened read-only so we can never corrupt what the bridge is writing.
DB_URI = f"file:{DB_PATH}?mode=ro"
SELF_DB_URI = f"file:{SELF_DB_PATH}?mode=ro"


def query(sql, args=(), uri=DB_URI):
    conn = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        conn.row_factory = sqlite3.Row
        return [dict(r) for r in conn.execute(sql, args)]
    finally:
        conn.close()


# When the extension last polled. This is the only evidence that the extension
# half of the pipeline is alive: its requests are sub-100ms, so you cannot catch
# them with lsof, and a dead extension looks exactly like "nobody messaged me".
# Exposed via /api/health so doctor.sh can check the one hop it otherwise cannot.
_last_poll_at = None

_self_ids = None


def self_ids():
    """Identifiers that mean "the bot" inside message text.

    Read from whatsmeow's device row rather than hardcoded, so relinking the bot
    to a different number can never silently break mention detection. Returns
    both the phone number and the LID, because WhatsApp writes an @-mention
    using the LID of the person mentioned, not their phone number.
    """
    global _self_ids
    if _self_ids is not None:
        return _self_ids

    ids = set()
    try:
        rows = query("SELECT jid, lid FROM whatsmeow_device LIMIT 1", uri=SELF_DB_URI)
        for value in (rows[0].get("jid"), rows[0].get("lid")) if rows else ():
            if not value:
                continue
            # "61400000000:2@s.whatsapp.net" / "253500000000000:2@lid" -> bare id
            ids.add(value.split("@")[0].split(":")[0])
    except Exception as e:
        print(f"wa-notifier: could not read self identity: {e}", flush=True)

    _self_ids = ids
    print(f"wa-notifier: self ids = {sorted(ids) or 'UNKNOWN'}", flush=True)
    return _self_ids


def is_addressed(row):
    """Should this inbound message wake the agent?

    DMs always count: someone messaged the bot directly. Group messages only
    count when the bot is actually being spoken to, either by @-mention or by
    replying to something the bot said. Without this a busy group would wake an
    Aside task for every unrelated line of chatter.
    """
    if not (row.get("chat_jid") or "").endswith("@g.us"):
        return True
    if row.get("replies_to_self"):
        return True
    content = row.get("content") or ""
    return any(f"@{i}" in content for i in self_ids())


def max_rowid():
    rows = query("SELECT COALESCE(MAX(rowid), 0) AS m FROM messages")
    return rows[0]["m"] if rows else 0


def messages_since(since_rowid, limit=50):
    # is_from_me = 0 so the agent never notifies itself about its own sends,
    # which would otherwise create a feedback loop when it replies.
    rows = query(
        """
        SELECT m.rowid AS rowid,
               m.id AS msg_id,
               m.chat_jid,
               m.sender,
               m.content,
               m.timestamp,
               m.media_type,
               c.name AS chat_name,
               CASE WHEN m.quoted_message_id IS NOT NULL AND EXISTS (
                   SELECT 1 FROM messages q
                   WHERE q.id = m.quoted_message_id
                     AND q.chat_jid = m.chat_jid
                     AND q.is_from_me = 1
               ) THEN 1 ELSE 0 END AS replies_to_self
        FROM messages m
        LEFT JOIN chats c ON c.jid = m.chat_jid
        WHERE m.rowid > ? AND m.is_from_me = 0
        ORDER BY m.rowid ASC
        LIMIT ?
        """,
        (since_rowid, limit),
    )

    # head is the high-water mark of everything examined, not just what passed
    # the filter. The caller advances its cursor to head so ignored group
    # chatter is skipped once instead of being rescanned on every poll.
    head = max((r["rowid"] for r in rows), default=since_rowid)
    return [r for r in rows if is_addressed(r)], head


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # Declared once at the top: Python rejects a `global` statement that comes
        # after the name has already been read elsewhere in the same function.
        global _last_poll_at
        parsed = urlparse(self.path)

        if parsed.path == "/":
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError as e:
                self._send(500, json.dumps({"error": str(e)}))
            return

        if parsed.path == "/api/health":
            try:
                since = (
                    None if _last_poll_at is None else round(time.time() - _last_poll_at, 1)
                )
                self._send(
                    200,
                    json.dumps(
                        {
                            "ok": True,
                            "db": DB_PATH,
                            "selfIds": sorted(self_ids()),
                            "maxRowId": max_rowid(),
                            "lastPollSecondsAgo": since,
                        }
                    ),
                )
            except Exception as e:
                self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return

        if parsed.path == "/api/head":
            _last_poll_at = time.time()
            try:
                self._send(200, json.dumps({"maxRowId": max_rowid()}))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
            return

        if parsed.path == "/api/new":
            _last_poll_at = time.time()
            qs = parse_qs(parsed.query)
            try:
                since = int(qs.get("since", ["0"])[0])
            except ValueError:
                self._send(400, json.dumps({"error": "since must be an integer"}))
                return
            try:
                rows, head = messages_since(since)
                self._send(200, json.dumps({"messages": rows, "head": head}))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
            return

        self._send(404, json.dumps({"error": "not found"}))

    # Keep the launchd log readable instead of one line per poll.
    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    if not os.path.exists(DB_PATH):
        print(
            f"wa-notifier: WARNING {DB_PATH} does not exist yet. "
            "Has the bridge been paired and run at least once?",
            flush=True,
        )
    print(f"wa-notifier serving on http://{HOST}:{PORT}  (db: {DB_PATH})", flush=True)
    self_ids()
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
