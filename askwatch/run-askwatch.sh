#!/bin/zsh
set -euo pipefail
source "$HOME/Library/Application Support/aside-whatsapp/env.sh"
exec "${ASIDE_WA_PYTHON_BIN:-/usr/bin/python3}" "${ASIDE_WA_REPO}/askwatch/server.py"
