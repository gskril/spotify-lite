#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH="$ROOT_DIR/.build/DerivedData/Build/Products/Release/SpotifyLite.app"

if [ ! -d "$APP_PATH" ]; then
  "$ROOT_DIR/Scripts/build.sh"
fi

open "$APP_PATH"
