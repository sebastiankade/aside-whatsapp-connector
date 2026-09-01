#!/usr/bin/env bash
# Shared paths, labels and helpers. Sourced by every script in this directory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="aside-whatsapp"
APP_SUPPORT="$HOME/Library/Application Support/$NAMESPACE"
LOG_DIR="$HOME/Library/Logs/$NAMESPACE"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
ENV_FILE="$APP_SUPPORT/env.sh"

LABEL_BRIDGE="com.$NAMESPACE.bridge"
LABEL_MCP="com.$NAMESPACE.mcp"
LABEL_NOTIFIER="com.$NAMESPACE.notifier"
LABEL_MONITOR="com.$NAMESPACE.monitor"

ALL_LABELS=("$LABEL_BRIDGE" "$LABEL_MCP" "$LABEL_NOTIFIER" "$LABEL_MONITOR")

GUI_DOMAIN="gui/$(id -u)"

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '  %s.%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %sx%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "This project is macOS only (it uses launchd and Chrome notifications)."
}

load_env() {
  [ -f "$ENV_FILE" ] || die "Not installed yet: $ENV_FILE is missing. Run scripts/install.sh first."
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
}

# Everything an agent or sandboxed process writes gets flagged with
# com.apple.quarantine. A quarantined file runs fine from an interactive
# terminal but Gatekeeper blocks it the moment launchd tries to run it, which
# surfaces as an "Apple could not verify..." dialog at login. Strip it from
# every path we create, including the plists.
unquarantine() {
  for p in "$@"; do
    [ -e "$p" ] && xattr -dr com.apple.quarantine "$p" 2>/dev/null || true
  done
}

# Resolve a binary that may not be on launchd's minimal PATH.
find_bin() {
  local name="$1"; shift
  local candidate
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  for candidate in "$@"; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

port_is_open() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

agent_loaded() { launchctl print "$GUI_DOMAIN/$1" >/dev/null 2>&1; }
