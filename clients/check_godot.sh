#!/usr/bin/env bash
# Check the generated Godot addon (godot_addons/addons/gamend, written by
# generate_godot.sh) in a headless Godot:
#
#   clients/check_godot.sh                          # every addon script compiles
#   clients/check_godot.sh http://127.0.0.1:4000    # ...and live calls against a server
#
# GODOT_BIN names the Godot 4 binary; without it, `godot` on PATH, then the
# macOS app. The live run signs in with a fresh device id, so the server needs
# device login enabled.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ADDON="$ROOT_DIR/godot_addons/addons/gamend"
PROJECT="$ROOT_DIR/tmp/godot_check"

GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  if command -v godot >/dev/null 2>&1; then
    GODOT="$(command -v godot)"
  elif [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
    GODOT=/Applications/Godot.app/Contents/MacOS/Godot
  else
    echo "error: set GODOT_BIN to a Godot 4 binary" >&2
    exit 2
  fi
fi

if [ ! -d "$ADDON" ]; then
  echo "error: $ADDON is missing; run clients/generate_godot.sh first" >&2
  exit 2
fi

# A throwaway project: the addon, the Phoenix client it depends on, and the
# two check scripts. Rebuilt every run so no stale class cache survives.
rm -rf "$PROJECT"
mkdir -p "$PROJECT/addons"
cp -R "$ADDON" "$ROOT_DIR/godot_addons/addons/phoenix_channels" "$PROJECT/addons/"
cp "$ROOT_DIR/clients/godot_check/"*.gd "$PROJECT/"
printf '[application]\nconfig/name="gamend_check"\n' > "$PROJECT/project.godot"

# The editor import builds the global class cache the scripts resolve against.
"$GODOT" --headless --editor --quit --path "$PROJECT" > "$PROJECT/import.log" 2>&1

"$GODOT" --headless --path "$PROJECT" --script res://check_all.gd 2>&1 \
  | grep -E "^(checked=|FAILED)|SCRIPT ERROR|Parse Error"

if [ "$#" -gt 0 ]; then
  "$GODOT" --headless --path "$PROJECT" --script res://smoke.gd -- "$1" 2>&1 \
    | grep -E "^(ok|FAIL|failures=)|SCRIPT ERROR"
fi
