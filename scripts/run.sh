#!/bin/sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOVE_BIN=${LOVE_BIN:-"$HOME/.local/opt/love.app/Contents/MacOS/love"}
exec "$LOVE_BIN" "$ROOT" "$@"
