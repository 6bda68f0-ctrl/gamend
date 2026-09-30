#!/usr/bin/env bash
# Write the C++ SDK into cpp_sdk/, the way generate_balaur.sh writes the
# Balaur one: the mix task refreshes the OpenAPI document, then
# clients/sdkgen turns it and the realtime table into the generated half and
# copies clients/cpp_template/ over the top.
#
#   clients/generate_cpp.sh            # regenerate
#   clients/generate_cpp.sh --check    # fail when cpp_sdk/ is stale
#
# cpp_sdk/ is not committed. CI runs this with APP_VERSION set, which stamps
# the version into version.hpp and so into the CMake package.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT_DIR"

if [ "${1:-}" != "--check" ]; then
  echo "Writing clients/godot/openapi.json from GamendWeb.ApiSpec"
  mix openapi.spec.json --spec GamendWeb.ApiSpec --filename clients/godot/openapi.json --pretty=true
fi

python3 clients/sdkgen cpp "$@"

if [ -n "${APP_VERSION:-}" ]; then
  echo "Stamping ${APP_VERSION} into the SDK"
  cat > cpp_sdk/include/gamend/version.hpp <<VERSION
// The Gamend release this SDK was generated from. Stamped by CI; a local
// generation leaves it as it is.
#pragma once

#define GAMEND_VERSION "${APP_VERSION}"
VERSION
fi
