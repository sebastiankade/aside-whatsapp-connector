#!/usr/bin/env bash
#
# Runs the bridge in the foreground so you can scan the pairing QR code.
# Once you see "Connected to WhatsApp", press Ctrl-C and run scripts/start.sh.
#
# Pairing persists in whatsapp-bridge/store/whatsapp.db, so you only ever do
# this once. Restarts, reboots and upgrades do not re-prompt.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env

if agent_loaded "$LABEL_BRIDGE"; then
  die "The bridge LaunchAgent is running and already holds the WhatsApp socket.
     Stop it first:  scripts/stop.sh
     Two processes on one account causes a 'connectionReplaced' (440) loop."
fi

say ""
say "${C_BOLD}Before you scan, read this. It will save you twenty minutes.${C_RESET}"
say ""
say "  ${C_BOLD}1. Use mobile data on the phone, not WiFi.${C_RESET}"
say "     The single most common failure is 'Check your internet connection and"
say "     try again' on the phone. It is not your internet. Turn WiFi off on the"
say "     phone, scan over LTE/5G, turn WiFi back on afterwards."
say ""
say "  ${C_BOLD}2. Use a light terminal theme, and make this window wide.${C_RESET}"
say "     The QR is drawn with half-block characters. It inverts on dark themes"
say "     and becomes unscannable, and it line-wraps into noise in a narrow window."
say ""
say "  ${C_BOLD}3. The QR is printed once per launch and expires in ~20s.${C_RESET}"
say "     If it goes stale, do not wait for a new one. Ctrl-C and re-run this script."
say ""
say "  On the phone: WhatsApp > Settings > Linked Devices > Link a Device."
say "  It will appear as: ${C_BOLD}${WHATSAPP_DEVICE_NAME}${C_RESET}"
say ""
if [ "${ASIDE_WA_NONINTERACTIVE:-0}" != "1" ]; then
  printf "Press Enter when ready. "
  read -r _
fi

say ""
step "Starting bridge in the foreground (Ctrl-C when connected)"
say ""

cd "$ASIDE_WA_BRIDGE_DIR"
exec "$ASIDE_WA_BRIDGE_BINARY"
