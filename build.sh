#!/bin/bash
# Builds Seek.app into ./build. Requires Xcode or the Command Line Tools (xcode-select --install).
#   ./build.sh          build/Seek.app
#   ./build.sh --dmg    also build/Seek.dmg (drag-to-Applications installer)
# Signing: uses a code-signing identity named "Seek Dev" (or $SEEK_SIGN_IDENTITY) if your keychain has one,
# so macOS keeps Accessibility/Automation permissions across rebuilds. Otherwise signs ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Seek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Seek" "$APP/Contents/MacOS/Seek"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SEEK_SIGN_IDENTITY:-Seek Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with “${IDENTITY}”"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE=build/dmg
    rm -rf "$STAGE" build/Seek.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Seek -srcfolder "$STAGE" -ov -format UDZO build/Seek.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Built build/Seek.dmg"
fi

echo "Install it:    ./install.sh"
echo "Benchmark it:  $APP/Contents/MacOS/Seek --bench saf invoice \"read me\""
