#!/usr/bin/env bash
#
# Installs the aside-whatsapp-connector stack:
#   1. fetches / updates verygoodplugins/whatsapp-mcp
#   2. builds the Go bridge binary and syncs the Python MCP server
#   3. writes a single env.sh that every component sources
#   4. generates four LaunchAgents (bridge, mcp, notifier, monitor)
#
# It deliberately does NOT start anything. Pairing has to happen first, in the
# foreground, so you can scan the QR code. Run scripts/pair.sh next.
#
# Safe to re-run: it is idempotent and will rewrite config in place.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ------------------------------------------------------------- defaults ----

MCP_DIR="$HOME/Dev/whatsapp-mcp"
MCP_REPO="https://github.com/verygoodplugins/whatsapp-mcp.git"
DEVICE_NAME="Aside Worker"
BRIDGE_PORT=8080
MCP_PORT=8009
NOTIFIER_PORT=8011
SKIP_BUILD=0

usage() {
  cat <<EOF
Usage: scripts/install.sh [options]

  --mcp-dir PATH        Where to clone/find whatsapp-mcp   (default: $MCP_DIR)
  --device-name NAME    Label shown in WhatsApp > Linked Devices
                                                           (default: $DEVICE_NAME)
  --bridge-port N       Go bridge REST API port            (default: $BRIDGE_PORT)
  --mcp-port N          MCP server port                    (default: $MCP_PORT)
  --notifier-port N     wa-notifier port                   (default: $NOTIFIER_PORT)
  --skip-build          Reuse the existing bridge binary and venv
  -h, --help            Show this message

Changing --notifier-port also requires editing extension/manifest.json and
extension/background.js, which hardcode the URL.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mcp-dir)       MCP_DIR="$2"; shift 2 ;;
    --device-name)   DEVICE_NAME="$2"; shift 2 ;;
    --bridge-port)   BRIDGE_PORT="$2"; shift 2 ;;
    --mcp-port)      MCP_PORT="$2"; shift 2 ;;
    --notifier-port) NOTIFIER_PORT="$2"; shift 2 ;;
    --skip-build)    SKIP_BUILD=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

MCP_DIR="${MCP_DIR/#\~/$HOME}"
require_macos

say ""
say "${C_BOLD}aside-whatsapp-connector installer${C_RESET}"
dim  "repo: $REPO_ROOT"
say ""

# ------------------------------------------------------------- preflight ----

step "Checking prerequisites"

command -v git >/dev/null 2>&1 || die "git not found. Install Xcode Command Line Tools: xcode-select --install"
ok "git"

# Deliberately prefer the system python over whatever is first on PATH. The
# notifier is stdlib-only, so it needs nothing else, and /usr/bin/python3 is the
# one interpreter guaranteed to still exist after a venv is deleted, a pyenv
# shim changes, or a tool that shipped its own runtime is updated. A launchd
# service pointed at a disposable interpreter fails silently at next login.
if [ -x /usr/bin/python3 ]; then
  PYTHON_BIN=/usr/bin/python3
else
  PYTHON_BIN="$(find_bin python3)" \
    || die "python3 not found. Install Xcode Command Line Tools: xcode-select --install"
fi
ok "python3  $PYTHON_BIN"

if [ "$SKIP_BUILD" -eq 0 ]; then
  GO_BIN="$(find_bin go /usr/local/go/bin/go "$HOME/sdk/go/bin/go" /opt/homebrew/bin/go)" || {
    err "go not found."
    dim "  Install with:  brew install go"
    dim "  Or download the official tarball from https://go.dev/dl/ and extract to ~/sdk/go"
    exit 1
  }
  ok "go       $GO_BIN  ($("$GO_BIN" version | awk '{print $3}'))"
fi

UV_BIN="$(find_bin uv "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.hermes/bin/uv")" || {
  err "uv not found."
  dim "  Install with:  curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
}
ok "uv       $UV_BIN"

for p in "$BRIDGE_PORT" "$MCP_PORT" "$NOTIFIER_PORT"; do
  if port_is_open "$p" && ! agent_loaded "$LABEL_BRIDGE"; then
    warn "Port $p already has something listening on it. If that is not this stack, pick a different port."
  fi
done

# --------------------------------------------------------------- fetch -----

step "Fetching whatsapp-mcp"

if [ -d "$MCP_DIR/.git" ]; then
  ok "Reusing existing checkout at $MCP_DIR"
  dim "  (not pulling automatically; run 'git -C $MCP_DIR pull' yourself if you want to update)"
elif [ -e "$MCP_DIR" ]; then
  die "$MCP_DIR exists but is not a git checkout. Move it aside or pass --mcp-dir."
else
  mkdir -p "$(dirname "$MCP_DIR")"
  git clone --depth 1 "$MCP_REPO" "$MCP_DIR"
  ok "Cloned into $MCP_DIR"
fi

BRIDGE_DIR="$MCP_DIR/whatsapp-bridge"
SERVER_DIR="$MCP_DIR/whatsapp-mcp-server"
BRIDGE_BIN="$BRIDGE_DIR/whatsapp-bridge"
STORE_DIR="$BRIDGE_DIR/store"

[ -d "$BRIDGE_DIR" ] || die "Expected $BRIDGE_DIR to exist. Is --mcp-dir pointing at the right repo?"
[ -d "$SERVER_DIR" ] || die "Expected $SERVER_DIR to exist. Is --mcp-dir pointing at the right repo?"

# --------------------------------------------------------------- build -----

if [ "$SKIP_BUILD" -eq 0 ]; then
  step "Building the Go bridge"
  # CGO is required because the bridge uses go-sqlite3. Building once into a
  # binary (rather than 'go run') matters: launchd restarts this process, and
  # recompiling on every restart is both slow and a source of flapping.
  ( cd "$BRIDGE_DIR" && CGO_ENABLED=1 "$GO_BIN" build -o whatsapp-bridge . )
  ok "Built $BRIDGE_BIN ($(du -h "$BRIDGE_BIN" | awk '{print $1}'))"

  step "Syncing the Python MCP server"
  ( cd "$SERVER_DIR" && "$UV_BIN" sync )
  ok "Dependencies installed"
else
  step "Skipping build (--skip-build)"
  [ -x "$BRIDGE_BIN" ] || die "--skip-build was passed but $BRIDGE_BIN does not exist."
  ok "Reusing $BRIDGE_BIN"
fi

# ----------------------------------------------------------------- env -----

step "Writing configuration"

mkdir -p "$APP_SUPPORT" "$APP_SUPPORT/state" "$LOG_DIR" "$LAUNCH_AGENTS" "$STORE_DIR"

# The upstream .env is read by NEITHER component automatically - the Go binary
# and the Python server both ignore it. Every launcher below explicitly sources
# env.sh instead. We still write the .env so that running upstream's own
# run scripts by hand behaves the same way.
cat > "$MCP_DIR/.env" <<EOF
# Generated by aside-whatsapp-connector. Edit env.sh instead:
#   $ENV_FILE

WHATSAPP_BRIDGE_PORT=$BRIDGE_PORT
WHATSAPP_API_URL=http://127.0.0.1:$BRIDGE_PORT/api

# Leaving the webhook on makes the bridge POST every inbound message to an
# unvetted localhost port. This stack does not use it: the notifier reads the
# database directly instead.
WEBHOOK_ENABLED=false

# Don't echo our own outbound messages back through the pipeline.
FORWARD_SELF=false

# Shown under WhatsApp > Settings > Linked Devices. Applied at pair time only.
WHATSAPP_DEVICE_NAME="$DEVICE_NAME"

WHATSAPP_DB_PATH=$STORE_DIR/messages.db
WHATSMEOW_DB_PATH=$STORE_DIR/whatsapp.db

# One HTTP server shared by every agent, instead of each client spawning its
# own stdio copy and fighting over the single WhatsApp socket.
WHATSAPP_MCP_TRANSPORT=http
WHATSAPP_MCP_HOST=127.0.0.1
WHATSAPP_MCP_PORT=$MCP_PORT
EOF
ok "Wrote $MCP_DIR/.env"

cat > "$ENV_FILE" <<EOF
# Generated by aside-whatsapp-connector on $(date '+%Y-%m-%d %H:%M:%S').
# Single source of truth. Every launcher and script sources this file.
# Re-run scripts/install.sh to regenerate, or edit in place and restart:
#   scripts/stop.sh && scripts/start.sh

export ASIDE_WA_REPO='$REPO_ROOT'
export ASIDE_WA_MCP_DIR='$MCP_DIR'
export ASIDE_WA_BRIDGE_DIR='$BRIDGE_DIR'
export ASIDE_WA_SERVER_DIR='$SERVER_DIR'
export ASIDE_WA_BRIDGE_BINARY='$BRIDGE_BIN'
export ASIDE_WA_STORE_DIR='$STORE_DIR'
export ASIDE_WA_LOG_DIR='$LOG_DIR'
export ASIDE_WA_STATE_DIR='$APP_SUPPORT/state'
export ASIDE_WA_UV_BIN='$UV_BIN'
export ASIDE_WA_PYTHON_BIN='$PYTHON_BIN'

export WHATSAPP_BRIDGE_PORT='$BRIDGE_PORT'
export WHATSAPP_API_URL='http://127.0.0.1:$BRIDGE_PORT/api'
export WEBHOOK_ENABLED='false'
export FORWARD_SELF='false'
export WHATSAPP_DEVICE_NAME='$DEVICE_NAME'

export WHATSAPP_DB_PATH='$STORE_DIR/messages.db'
export WHATSMEOW_DB_PATH='$STORE_DIR/whatsapp.db'
export WHATSAPP_MCP_TRANSPORT='http'
export WHATSAPP_MCP_HOST='127.0.0.1'
export WHATSAPP_MCP_PORT='$MCP_PORT'

export WA_NOTIFIER_DB='$STORE_DIR/messages.db'
export WA_NOTIFIER_SELF_DB='$STORE_DIR/whatsapp.db'
export WA_NOTIFIER_HOST='127.0.0.1'
export WA_NOTIFIER_PORT='$NOTIFIER_PORT'
EOF
chmod 600 "$ENV_FILE"
ok "Wrote $ENV_FILE"

# ------------------------------------------------------------ launchers ----

step "Generating launchers"

write_exec() {
  local path="$1"; shift
  cat > "$path"
  chmod +x "$path"
  ok "$(basename "$path")"
}

write_exec "$APP_SUPPORT/run-bridge.sh" <<EOF
#!/bin/zsh
# The ONLY process that holds a WhatsApp connection.
set -euo pipefail
source '$ENV_FILE'
cd "\$ASIDE_WA_BRIDGE_DIR"
exec "\$ASIDE_WA_BRIDGE_BINARY"
EOF

write_exec "$APP_SUPPORT/run-mcp.sh" <<EOF
#!/bin/zsh
# Holds no WhatsApp connection; proxies to the bridge's REST API and reads the
# message database directly.
set -euo pipefail
source '$ENV_FILE'
cd "\$ASIDE_WA_SERVER_DIR"
exec "\$ASIDE_WA_UV_BIN" run main.py
EOF

write_exec "$APP_SUPPORT/run-notifier.sh" <<EOF
#!/bin/zsh
set -euo pipefail
source '$ENV_FILE'
exec "\$ASIDE_WA_PYTHON_BIN" '$REPO_ROOT/notifier/server.py'
EOF

write_exec "$APP_SUPPORT/monitor.sh" <<'MONEOF'
#!/bin/zsh
# Polled by launchd every 60s. Raises a macOS notification when the stack is
# unhealthy, and only once per distinct problem, so a long outage does not
# produce one alert per minute.
set -euo pipefail
source "$HOME/Library/Application Support/aside-whatsapp/env.sh"

STATE_DIR="$ASIDE_WA_STATE_DIR"
BRIDGE_LOG="$ASIDE_WA_LOG_DIR/bridge.out.log"
TOKEN_FILE="$ASIDE_WA_STORE_DIR/.bridge-token"
mkdir -p "$STATE_DIR"

notify() {
  osascript -e 'on run argv' \
            -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
            -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
}
alert_once() {
  local marker="$STATE_DIR/$1.alerted"
  [[ -f "$marker" ]] || { notify "$2" "$3"; : > "$marker"; }
}
clear_alert() { rm -f "$STATE_DIR/$1.alerted"; }

USER_ID="$(id -u)"
if ! launchctl print "gui/$USER_ID/com.aside-whatsapp.bridge" >/dev/null 2>&1; then
  alert_once down "WhatsApp bridge down" "The bridge LaunchAgent is not loaded."
  exit 0
fi
clear_alert down

TOKEN="${WHATSAPP_BRIDGE_TOKEN:-}"
[[ -z "$TOKEN" && -r "$TOKEN_FILE" ]] && TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
if [[ -z "$TOKEN" ]]; then
  alert_once token "WhatsApp bridge token missing" "Cannot read $TOKEN_FILE."
  exit 0
fi
clear_alert token

API="${WHATSAPP_API_URL%/}"
resp="$(curl -sS -m 5 -H "Authorization: Bearer $TOKEN" -w $'\n%{http_code}' "$API/health" 2>/dev/null || true)"
if [[ -z "$resp" ]]; then
  alert_once api "WhatsApp bridge unreachable" "No response from $API/health."
  exit 0
fi
code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
if [[ "$code" == "401" || "$code" == "403" ]]; then
  alert_once token "WhatsApp bridge token invalid" "The health endpoint rejected the token in $TOKEN_FILE."
  exit 0
fi
if [[ "$code" != "200" && "$code" != "503" ]]; then
  alert_once api "WhatsApp bridge unreachable" "Unexpected HTTP $code from $API/health."
  exit 0
fi
clear_alert api

# The notifier is the piece that actually wakes the agent, so a healthy bridge
# with a dead notifier is a silent failure worth alerting on.
if ! curl -sS -m 5 -o /dev/null "http://127.0.0.1:${WA_NOTIFIER_PORT}/api/head" 2>/dev/null; then
  alert_once notifier "WhatsApp notifier down" "No response on port ${WA_NOTIFIER_PORT}. Messages will not reach your agent."
else
  clear_alert notifier
fi

if print -r -- "$body" | grep -Eq '"connected"[[:space:]]*:[[:space:]]*true'; then
  clear_alert relink; clear_alert qr
else
  alert_once relink "WhatsApp relink needed" "The bridge is running but WhatsApp is disconnected."
  if [[ -f "$BRIDGE_LOG" ]] && tail -n 200 "$BRIDGE_LOG" 2>/dev/null \
       | grep -Eiq 'Scan this QR code|Device logged out|QR code timed out|Timeout waiting for QR'; then
    alert_once qr "WhatsApp pairing needed" "Run scripts/pair.sh to scan a new QR code."
  else
    clear_alert qr
  fi
fi
MONEOF

# ---------------------------------------------------------- launchagents ---

step "Generating LaunchAgents"

# KeepAlive + ThrottleInterval 10 means a crashing component retries forever but
# no faster than once every 10s, which is what stops a misconfigured bridge from
# hammering WhatsApp and burning the session.
plist() {
  local label="$1" program="$2" workdir="$3" logbase="$4" extra="$5"
  cat > "$LAUNCH_AGENTS/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
      <string>$program</string>
    </array>
    <key>WorkingDirectory</key><string>$workdir</string>
    <key>RunAtLoad</key><true/>
$extra
    <key>StandardOutPath</key><string>$LOG_DIR/$logbase.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/$logbase.err.log</string>
  </dict>
</plist>
EOF
  ok "$label.plist"
}

KEEPALIVE='    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>'

plist "$LABEL_BRIDGE"   "$APP_SUPPORT/run-bridge.sh"   "$BRIDGE_DIR"  "bridge"   "$KEEPALIVE"
plist "$LABEL_MCP"      "$APP_SUPPORT/run-mcp.sh"      "$SERVER_DIR"  "mcp"      "$KEEPALIVE"
plist "$LABEL_NOTIFIER" "$APP_SUPPORT/run-notifier.sh" "$REPO_ROOT"   "notifier" "$KEEPALIVE"
plist "$LABEL_MONITOR"  "$APP_SUPPORT/monitor.sh"      "$APP_SUPPORT" "monitor"  '    <key>StartInterval</key><integer>60</integer>'

step "Clearing quarantine flags"
unquarantine "$REPO_ROOT" "$APP_SUPPORT" "$MCP_DIR"
for l in "${ALL_LABELS[@]}"; do unquarantine "$LAUNCH_AGENTS/$l.plist"; done
ok "Done (this is what stops Gatekeeper blocking the binary under launchd)"

# ----------------------------------------------------------------- next ----

say ""
say "${C_GREEN}${C_BOLD}Installed.${C_RESET} Nothing is running yet."
say ""
say "${C_BOLD}Next:${C_RESET}"
say "  1. ${C_BOLD}scripts/pair.sh${C_RESET}      scan the QR with the phone that will be the bot"
say "  2. ${C_BOLD}scripts/start.sh${C_RESET}     load all four LaunchAgents"
say "  3. ${C_BOLD}scripts/doctor.sh${C_RESET}    verify every component is healthy"
say "  4. Load ${C_BOLD}extension/${C_RESET} in Chrome via chrome://extensions (Developer mode > Load unpacked)"
say "  5. Register the MCP server and the routine in Aside - see ${C_BOLD}docs/SETUP.md${C_RESET} step 6-7"
say ""
