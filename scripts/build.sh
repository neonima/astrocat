#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/AstroCat.app"
CONTENTS="$APP/Contents"

cargo build --release -p astrocat-ffi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

xcrun -sdk macosx metal -O -c apps/AstroCat/Shaders.metal -o target/Shaders.air
xcrun -sdk macosx metallib target/Shaders.air -o "$CONTENTS/Resources/default.metallib"

swiftc \
	-O -parse-as-library \
	-target arm64-apple-macos14.0 \
	-import-objc-header include/astrocat.h \
	-o "$CONTENTS/MacOS/AstroCat" \
	apps/AstroCat/Sources/*.swift \
	-L target/release -lastrocat_ffi \
	-framework AppKit -framework Metal -framework MetalKit -framework SwiftUI

cp apps/AstroCat/Info.plist "$CONTENTS/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "built $APP"
