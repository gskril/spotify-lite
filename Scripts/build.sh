#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
xcodegen generate
xcodebuild \
  -project SpotifyLite.xcodeproj \
  -scheme SpotifyLite \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
xcodebuild \
  -project SpotifyLite.xcodeproj \
  -scheme SpotifyLite \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
