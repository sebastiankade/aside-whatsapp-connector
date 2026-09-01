#!/usr/bin/env bash
#
# Removes the LaunchAgents and generated support files.
#
# By default it LEAVES the WhatsApp pairing alone, so you can reinstall without
# scanning a QR again. Pass --purge to also delete the paired session, which
# frees the linked-device slot on your phone.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

step "Stopping services"
for label in "${ALL_LABELS[@]}"; do
  launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true
  rm -f "$LAUNCH_AGENTS/$label.plist"
  ok "$label removed"
done

if [ "$PURGE" -eq 1 ]; then
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
    step "Purging paired session"
    warn "This logs the bot out. You will need to scan a QR code again."
    if [ "${ASIDE_WA_NONINTERACTIVE:-0}" = "1" ]; then
      die "--purge needs an interactive confirmation. Refusing to run unattended."
    fi
    printf "Type 'yes' to confirm: "
    read -r confirm
    if [ "$confirm" = "yes" ]; then
      rm -rf "$ASIDE_WA_STORE_DIR"
      ok "Deleted $ASIDE_WA_STORE_DIR"
      warn "Also remove the stale entry on your phone: WhatsApp > Linked Devices > log out."
    else
      dim "  Skipped."
    fi
  fi
fi

step "Removing generated files"
rm -rf "$APP_SUPPORT"
ok "$APP_SUPPORT"
dim "  Logs kept at $LOG_DIR (delete by hand if you want them gone)"

say ""
say "Done. Still to remove by hand, if you want a clean slate:"
say "  - the Chrome extension            chrome://extensions"
say "  - the MCP server entry in Aside   Settings > MCP"
say "  - the Aside event routine"
say "  - the whatsapp-mcp checkout       (wherever you cloned it)"
say ""
