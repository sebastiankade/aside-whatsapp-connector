#!/usr/bin/env bash
#
# Loads all four LaunchAgents. They start now and again at every login.
#
# Note on the error you are about to maybe see: `launchctl bootstrap` on modern
# macOS often prints "Bootstrap failed: 5: Input/output error" and yet the
# service loads perfectly. The exit status of bootstrap is not trustworthy.
# That is why this script verifies with `launchctl print` afterwards instead of
# believing the return code.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env

step "Loading LaunchAgents"

for label in "${ALL_LABELS[@]}"; do
  plist="$LAUNCH_AGENTS/$label.plist"
  [ -f "$plist" ] || { warn "$label.plist missing, skipping (re-run install.sh)"; continue; }

  launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$GUI_DOMAIN" "$plist" >/dev/null 2>&1 || true
  launchctl enable "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true
  launchctl kickstart "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true

  if agent_loaded "$label"; then ok "$label"; else err "$label failed to load"; fi
done

say ""
# The bridge and notifier are up in a second or two. The MCP server is the slow
# one: `uv run` resolves and may build the environment on a cold venv, which
# measured at roughly 50 seconds on a first install. A 20s wait here reports a
# healthy stack as broken, so be patient.
step "Waiting for services to come up (the MCP server can take a minute)"
for i in $(seq 1 90); do
  if port_is_open "$WHATSAPP_BRIDGE_PORT" && port_is_open "$WHATSAPP_MCP_PORT" && port_is_open "$WA_NOTIFIER_PORT"; then
    ok "all three ports listening after ${i}s"
    break
  fi
  sleep 1
done

say ""
exec "$REPO_ROOT/scripts/doctor.sh"
