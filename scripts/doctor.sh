#!/usr/bin/env bash
#
# Health check for every layer of the stack, in the order the data flows:
#
#   WhatsApp -> Go bridge -> messages.db -> notifier -> Chrome extension -> Aside
#
# Run this first whenever something stops working. It tells you which hop is
# broken instead of making you guess.
#
# Exits 0 when every automated check passes, 1 otherwise.
# Pass --json for machine-readable output (for agents and CI).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

load_env

FAILED=0
JSON_ROWS=""

json_escape() { printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# record <group> <name> <pass|fail|warn> <detail>
record() {
  local group="$1" name="$2" status="$3" detail="${4:-}"
  [ "$status" = "fail" ] && FAILED=1
  JSON_ROWS="$JSON_ROWS{\"group\":\"$(json_escape "$group")\",\"check\":\"$(json_escape "$name")\",\"status\":\"$status\",\"detail\":\"$(json_escape "$detail")\"},"
  [ "$JSON" -eq 1 ] && return 0
  case "$status" in
    pass) ok   "$name${detail:+  $C_DIM$detail$C_RESET}" ;;
    warn) warn "$name${detail:+  $detail}" ;;
    fail) err  "$name${detail:+  ->  $detail}" ;;
  esac
  return 0
}

section() { [ "$JSON" -eq 1 ] || { say ""; step "$*"; }; }
hint()    { [ "$JSON" -eq 1 ] || dim "     $*"; }

[ "$JSON" -eq 1 ] || { say ""; say "${C_BOLD}aside-whatsapp-connector doctor${C_RESET}"; }

# ------------------------------------------------------- 1. launchagents ---

section "1. LaunchAgents"
for label in "${ALL_LABELS[@]}"; do
  if agent_loaded "$label"; then
    record launchd "$label" pass "loaded"
  else
    record launchd "$label" fail "not loaded; run scripts/start.sh"
  fi
done

# ------------------------------------------------------------- 2. bridge ---

section "2. Go bridge (owns the WhatsApp connection)"

if port_is_open "$WHATSAPP_BRIDGE_PORT"; then
  record bridge "port $WHATSAPP_BRIDGE_PORT" pass "listening"
else
  record bridge "port $WHATSAPP_BRIDGE_PORT" fail "nothing listening; tail $ASIDE_WA_LOG_DIR/bridge.out.log"
fi

TOKEN_FILE="$ASIDE_WA_STORE_DIR/.bridge-token"
if [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE" || true)"
  record bridge "auth token" pass "${#TOKEN} chars"
else
  TOKEN=""
  record bridge "auth token" fail "unreadable at $TOKEN_FILE"
fi

if [ -n "$TOKEN" ]; then
  HEALTH="$(curl -sS -m 5 -H "Authorization: Bearer $TOKEN" "${WHATSAPP_API_URL%/}/health" 2>/dev/null || true)"
  if [ -z "$HEALTH" ]; then
    record bridge "whatsapp connection" fail "no response from ${WHATSAPP_API_URL%/}/health"
  elif printf '%s' "$HEALTH" | grep -Eq '"connected"[[:space:]]*:[[:space:]]*true'; then
    record bridge "whatsapp connection" pass "connected"
  else
    record bridge "whatsapp connection" fail "bridge up but WhatsApp DISCONNECTED"
    hint "If the log mentions a QR code:  scripts/stop.sh && scripts/pair.sh"
  fi
fi

# ---------------------------------------------------------------- 3. db ---

section "3. Message database"
if [ -f "$WHATSAPP_DB_PATH" ]; then
  record db "messages.db" pass "$(du -h "$WHATSAPP_DB_PATH" 2>/dev/null | awk '{print $1}' || echo '?') at $WHATSAPP_DB_PATH"
else
  record db "messages.db" fail "missing at $WHATSAPP_DB_PATH; has the bridge ever connected?"
fi

# --------------------------------------------------------------- 4. mcp ---

section "4. MCP server"

if port_is_open "$WHATSAPP_MCP_PORT"; then
  record mcp "port $WHATSAPP_MCP_PORT" pass "listening"
else
  record mcp "port $WHATSAPP_MCP_PORT" fail "nothing listening; tail $ASIDE_WA_LOG_DIR/mcp.err.log"
fi

# A bare GET on /mcp returns 406 BY DESIGN, because streamable-http requires an
# Accept header offering text/event-stream. So 406 means healthy. Probe with a
# real initialize POST rather than trusting a GET.
MCP_URL="http://$WHATSAPP_MCP_HOST:$WHATSAPP_MCP_PORT/mcp"
# uv can take the better part of a minute to bring the server up from a cold
# venv, so a single probe right after start.sh reports a false failure. Retry
# briefly before believing it. curl already prints 000 on a connection failure;
# do not add another fallback or you get a nonsense code like "000000".
mcp_probe() {
  curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"doctor","version":"1"}}}' \
    2>/dev/null
}

# The `|| true` is load-bearing. curl exits non-zero on a connection failure or
# timeout, and common.sh sets `set -euo pipefail`, so without it a single
# transient failure kills doctor mid-run with curl's exit code instead of
# reporting the check. Do not use `|| echo 000` here: curl has already printed
# 000 via -w, and the two concatenate into a nonsense "HTTP 000000".
CODE="$(mcp_probe || true)"
for _ in 1 2 3 4 5; do
  [ "$CODE" = "200" ] && break
  sleep 3
  CODE="$(mcp_probe || true)"
done

case "$CODE" in
  200) record mcp "initialize handshake" pass "$MCP_URL" ;;
  000) record mcp "initialize handshake" fail "no response at $MCP_URL after 5 attempts" ;;
  404) record mcp "initialize handshake" fail "HTTP 404 - something else is squatting port $WHATSAPP_MCP_PORT" ;;
  *)   record mcp "initialize handshake" fail "unexpected HTTP $CODE from $MCP_URL" ;;
esac

# ---------------------------------------------------------- 5. notifier ---

section "5. Notifier"

if port_is_open "$WA_NOTIFIER_PORT"; then
  record notifier "port $WA_NOTIFIER_PORT" pass "listening"
else
  record notifier "port $WA_NOTIFIER_PORT" fail "nothing listening; tail $ASIDE_WA_LOG_DIR/notifier.err.log"
fi

NOTE="$(curl -sS -m 5 "http://127.0.0.1:$WA_NOTIFIER_PORT/api/health" 2>/dev/null || true)"
if [ -z "$NOTE" ]; then
  record notifier "health endpoint" fail "no response"
elif ! printf '%s' "$NOTE" | grep -q '"selfIds"'; then
  # /api/health was added after the first release. A 'not found' here means the
  # port is held by an older notifier, or by something else entirely.
  record notifier "health endpoint" fail "port $WA_NOTIFIER_PORT answered but has no /api/health; an older or unrelated server is running there"
  hint "Fix:  scripts/stop.sh && scripts/start.sh"
else
  ROWS="$(printf '%s' "$NOTE" | sed -n 's/.*"maxRowId":[[:space:]]*\([0-9]*\).*/\1/p')"
  IDS="$(printf '%s' "$NOTE" | sed -n 's/.*"selfIds":[[:space:]]*\[\([^]]*\)\].*/\1/p')"
  record notifier "database read" pass "maxRowId=${ROWS:-?}"
  if [ -z "$IDS" ]; then
    record notifier "self identity" fail "unknown; notifier cannot read whatsapp.db (check WA_NOTIFIER_SELF_DB)"
  else
    record notifier "self identity" pass "$IDS"
  fi

  # The extension is otherwise invisible: its polls are sub-100ms so lsof never
  # catches them, and an extension that is unloaded, crashed or pointed at the
  # wrong port looks identical to "nobody has messaged you". This is the check
  # that tells them apart.
  POLL="$(printf '%s' "$NOTE" | sed -n 's/.*"lastPollSecondsAgo":[[:space:]]*\([0-9.]*\).*/\1/p')"
  if printf '%s' "$NOTE" | grep -q '"lastPollSecondsAgo":[[:space:]]*null'; then
    record extension "polling" fail "nothing has ever polled; the Chrome extension is not running"
    hint "Load it: chrome://extensions > Developer mode > Load unpacked > $REPO_ROOT/extension"
  elif [ -z "$POLL" ]; then
    record extension "polling" warn "notifier is too old to report this; restart it"
  elif [ "${POLL%%.*}" -gt 120 ] 2>/dev/null; then
    record extension "polling" fail "last poll was ${POLL}s ago; expected every 30s"
    hint "The service worker may be asleep or erroring. Check its console."
  else
    record extension "polling" pass "last poll ${POLL}s ago"
  fi
fi

# -------------------------------------------------------- 6. quarantine ---

section "6. Gatekeeper quarantine"
# Check ONLY the files launchd actually executes or parses. Recursing over a
# whole repo is useless noise: a fresh `git clone` leaves every object in .git
# quarantined, and launchd never touches those. Flagging them sends people
# chasing a problem that does not exist.
QCOUNT=0
QPATHS="$ASIDE_WA_BRIDGE_BINARY
$REPO_ROOT/notifier/server.py
$APP_SUPPORT/run-bridge.sh
$APP_SUPPORT/run-mcp.sh
$APP_SUPPORT/run-notifier.sh
$APP_SUPPORT/monitor.sh"
for label in "${ALL_LABELS[@]}"; do
  QPATHS="$QPATHS
$LAUNCH_AGENTS/$label.plist"
done

while IFS= read -r p; do
  [ -n "$p" ] && [ -e "$p" ] || continue
  if xattr "$p" 2>/dev/null | grep -q com.apple.quarantine; then
    QCOUNT=$((QCOUNT + 1))
    hint "quarantined: $p"
  fi
done <<< "$QPATHS"
if [ "$QCOUNT" -eq 0 ]; then
  record quarantine "com.apple.quarantine" pass "clean"
else
  record quarantine "com.apple.quarantine" fail "$QCOUNT executable path(s) flagged; launchd will refuse them at next login"
  hint "Fix:  xattr -dr com.apple.quarantine '$REPO_ROOT' '$APP_SUPPORT' '$ASIDE_WA_MCP_DIR'"
  hint "      xattr -d  com.apple.quarantine '$LAUNCH_AGENTS'/com.aside-whatsapp.*.plist"
fi

# ------------------------------------------------------------- output ------

if [ "$JSON" -eq 1 ]; then
  printf '{"ok":%s,"checks":[%s]}\n' \
    "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
    "${JSON_ROWS%,}"
  exit "$FAILED"
fi

say ""
step "7. Cannot be checked from here"
dim "  - MCP server registered in Aside          tools appear only after toggling the server off/on"
dim "  - Event routine armed in Aside            titleIncludes filter 'WhatsApp: '"
dim "  - Notification permission granted         chrome://settings/content/notifications"
dim "  See docs/SETUP.md steps 6-8 and docs/TROUBLESHOOTING.md."

say ""
if [ "$FAILED" -eq 0 ]; then
  say "${C_GREEN}${C_BOLD}All automated checks passed.${C_RESET}"
else
  say "${C_RED}${C_BOLD}Some checks failed.${C_RESET} See docs/TROUBLESHOOTING.md."
fi
say ""
exit "$FAILED"
