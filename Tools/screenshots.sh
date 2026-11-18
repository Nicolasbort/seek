#!/bin/bash
# Regenerates the README screenshots in docs/screenshots/ from a fake home folder,
# so no real file names end up in the repo.
#
# Needs Screen Recording permission for your terminal app
# (System Settings → Privacy & Security → Screen & System Audio Recording).
#
# How it works: a second, demo copy of Seek runs with CFFIXED_USER_HOME pointing at a
# throwaway home (its own config, index and history; your real ones aren't touched).
# `--demo` puts a gradient behind the panel, and a seek:// argument opens each view.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -x build/Seek.app/Contents/MacOS/Seek ]] || ./build.sh
BIN="$PWD/build/Seek.app/Contents/MacOS/Seek"
OUT="$PWD/docs/screenshots"
mkdir -p "$OUT"

if ! screencapture -x "$(mktemp -t probe).png" 2>/dev/null; then
    echo "Screen capture is blocked. Allow your terminal in Screen & System Audio Recording, restart it, and try again." >&2
    exit 1
fi

# ---- Fake home (roots skip /Applications so your installed apps don't show up) ---------------------------------------------------------------
H=$(mktemp -d -t seek-demo-home)
trap 'pkill -f "$BIN --demo" 2>/dev/null || true; rm -rf "$H"' EXIT

files=(
  "Documents/Taxes/Tax Return 2025.pdf" "Documents/Taxes/Receipts 2025.numbers"
  "Documents/Invoices/Invoice 2026-031.pdf" "Documents/Invoices/Invoice 2026-032.pdf"
  "Documents/Invoices/Invoice Template.pages" "Documents/Lease Agreement.pdf" "Documents/Resume.pdf"
  "Documents/Budget 2026.numbers" "Documents/Presentations/Q3 Board Review.key"
  "Documents/Presentations/Product Roadmap.key" "Documents/Design Brief.pdf"
  "Downloads/design-assets.zip" "Downloads/invoice-acme-0412.pdf" "Downloads/Installer.dmg"
  "Downloads/brand-guidelines.pdf" "Desktop/Screenshot 2026-11-18 at 09.41.12.png" "Desktop/todo.txt"
  "Developer/aurora-web/package.json" "Developer/aurora-web/README.md" "Developer/aurora-web/src/index.ts"
  "Developer/aurora-web/src/design-tokens.ts" "Developer/notes-app/Package.swift"
  "Developer/notes-app/Sources/NotesApp/App.swift" "Developer/notes-app/Sources/NotesApp/Editor.swift"
  "Developer/dotfiles/zshrc" "Pictures/Iceland 2025/IMG_2041.jpg" "Pictures/Iceland 2025/IMG_2042.jpg"
  "Pictures/Wallpapers/Dunes.jpg" "Music/Playlists/Focus.m3u" "Movies/Product Demo.mov"
)
for f in "${files[@]}"; do mkdir -p "$H/$(dirname "$f")"; : > "$H/$f"; done
mkdir -p "$H/Design/Seek" "$H/Documents/Archive" "$H/Library" "$H/.config/seek"
sips -s format png -Z 1024 Resources/AppIcon.icns --out "$H/Design/Seek/Seek Icon.png" >/dev/null
printf '# Weekly sync\n\n- Ship the launch page by Friday\n- Review Q3 numbers\n' > "$H/Documents/Meeting Notes.md"
cat > "$H/.config/seek/config.json" <<'JSON'
{
  "hotkey": "ctrl+option+cmd+f12",
  "roots": ["~", "/System/Applications"],
  "excludeNames": ["node_modules", "__pycache__", "Pods", "DerivedData", ".build", "venv", ".venv"],
  "excludePaths": ["~/Library", "~/.Trash"],
  "excludePatterns": ["~/Developer/.*/dist$", "/build/(intermediates|tmp)$"],
  "includeHidden": false,
  "visibleRows": 8,
  "passwordsKeyword": "pw",
  "apwPath": ""
}
JSON

# ---- Capture -----------------------------------------------------------------
GEOM="$H/geometry.json"
MARGIN=70

run() { # url
    rm -f "$GEOM"
    CFFIXED_USER_HOME="$H" SEEK_DEMO_OUT="$GEOM" "$BIN" --demo "$1" >/dev/null 2>&1 &
    for _ in $(seq 1 100); do [[ -s "$GEOM" ]] && return 0; sleep 0.1; done
    echo "Seek didn't report its window for $1" >&2; return 1
}
stop() { pkill -f "$BIN --demo" 2>/dev/null || true; sleep 0.5; }
field() { /usr/bin/python3 -c "import json,sys; print(int(json.load(open('$GEOM'))['$1']))"; }

shot() { # name url [extra settle seconds]
    run "$2"                   # geometry is written once results (and preview) have landed
    sleep "${3:-0.6}"          # extra settle time for icons / Quick Look rendering
    local x y w h
    x=$(field x); y=$(field y); w=$(field w); h=$(field h)
    screencapture -x -R "$((x - MARGIN)),$((y - MARGIN)),$((w + 2 * MARGIN)),$((h + 2 * MARGIN))" "$OUT/$1.png"
    echo "  $1.png"
    stop
}

echo "Warming up the demo index…"
run "seek://search?q=a"; sleep 4; stop

echo "Capturing:"
shot search          "seek://search?q=notes"
shot system-settings "seek://search?q=screen"
shot actions         "seek://search?q=budget&select=1&actions=1"
shot quick-look      "seek://search?q=seek%20icon&select=1&preview=1" 1.5

run "seek://settings?tab=index"; sleep 0.8
screencapture -x -l "$(field window)" "$OUT/settings.png"; echo "  settings.png"
stop

echo "Saved to $OUT"
