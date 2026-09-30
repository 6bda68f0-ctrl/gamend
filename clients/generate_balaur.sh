#!/usr/bin/env bash
# Write the Balaur SDK, the way generate_godot.sh writes the Godot one: the
# mix task refreshes the OpenAPI document, then clients/sdkgen turns it and
# the realtime table into addons/gamend.
#
#   clients/generate_balaur.sh            # regenerate
#   clients/generate_balaur.sh --check    # fail when it is stale (CI)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT_DIR"

if [ "${1:-}" != "--check" ]; then
  echo "Writing clients/godot/openapi.json from GamendWeb.ApiSpec"
  mix openapi.spec.json --spec GamendWeb.ApiSpec --filename clients/godot/openapi.json --pretty=true
fi

python3 clients/sdkgen balaur "$@"

if [ -n "${APP_VERSION:-}" ]; then
  echo "Stamping ${APP_VERSION} into the addon"
  cat > balaur_addons/addons/gamend/version.rn <<VERSION
// Stamped by CI. A local generation leaves it as it is.
pub const GAMEND_VERSION = "${APP_VERSION}";
VERSION
fi
