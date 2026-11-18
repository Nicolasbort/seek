#!/bin/bash
# Builds Seek.app into ./build. Requires Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Seek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Seek" "$APP/Contents/MacOS/Seek"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it:        open $APP"
echo "Install it:    cp -R $APP /Applications/"
echo "Benchmark it:  $APP/Contents/MacOS/Seek --bench saf invoice \"read me\""
