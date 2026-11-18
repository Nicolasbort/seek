#!/bin/bash
# Builds Seek and installs it to /Applications, replacing a running copy, then starts it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
DEST=/Applications/Seek.app

if pgrep -xq Seek; then
    osascript -e 'quit app "Seek"' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Seek || break; sleep 0.1; done
    pkill -x Seek 2>/dev/null || true
fi

rm -rf "$DEST"
cp -R build/Seek.app "$DEST"
# Make Finder/Spotlight/Launchpad pick up the new icon and bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
touch "$DEST"
open "$DEST"
echo "Installed $DEST and started it."
echo "Turn on “Open Seek when you log in” in Seek Settings (⌘, in Seek) to start it automatically."
