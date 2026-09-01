#!/usr/bin/env bash
#
# Unloads all four LaunchAgents. Pairing is untouched: this stops the processes,
# it does not log the device out of WhatsApp. scripts/start.sh brings it all back
# with no QR scan.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

step "Unloading LaunchAgents"
for label in "${ALL_LABELS[@]}"; do
  if agent_loaded "$label"; then
    launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true
    if agent_loaded "$label"; then err "$label still loaded"; else ok "$label stopped"; fi
  else
    dim "  - $label was not running"
  fi
done
say ""
