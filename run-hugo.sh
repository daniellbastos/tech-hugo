#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUGO_BIN="/home/server/.openclaw/workspace/tools/hugo/hugo"
cd "$SCRIPT_DIR"
"$HUGO_BIN" server -D --bind 0.0.0.0 --baseURL http://localhost:1313/
