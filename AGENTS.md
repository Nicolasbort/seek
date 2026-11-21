# AGENTS.md — Seek

Context for anyone (human or AI agent) picking up this repo. Read this before changing code.

## What Seek is

A native macOS launcher, like Spotlight or Alfred, that searches **only apps, folders and files**. It is meant to replace Alfred for its owner. The goal is to be **faster than both Spotlight and Alfred**, with a clean **Liquid Glass** UI (macOS 26 Tahoe).

### Out of scope (deliberately)

- Clipboard history, snippets, workflows/plugins, contacts, music, web search, calculator, themes.
- A content index of its own. Searching inside files is handed off to Spotlight through the `in:` filter.

## Current status

- **The code has never been compiled.** All of it (~2,900 lines of Swift) was written in a Linux sandbox with no Swift toolchain or macOS SDK. Expect a round of compile fixes on the first `./build.sh`.
- No tests yet.
- Features are all implemented on paper (list below). None has been run.

### First tasks for whoever picks this up

1. Run `./build.sh` on a Mac with Xcode 26 and fix compile errors. The likely spots are listed under "Risky APIs".
2. Run `build/Seek.app/Contents/MacOS/Seek --bench` and record the numbers in this file.
3. Test the Passwords flows against a real Passwords app, and against `apw` if it's installed.
4. Add unit tests for `Matcher.score`, `ParsedQuery.parse`, `PathFilter.shouldIndex` and `IndexCache` round-trips. These are pure functions and the easiest to test.

## Build & run

```
./build.sh                       # swift build -c release, wraps into build/Seek.app (icon included), signs
./build.sh --dmg                 # also build/Seek.dmg (drag-to-Applications installer)
./install.sh                     # build, replace /Applications/Seek.app, start it
Tools/screenshots.sh             # regenerate docs/screenshots from a fake home (needs Screen Recording)
open build/Seek.app
build/Seek.app/Contents/MacOS/Seek --bench [queries…]   # headless benchmark vs `mdfind -name`
```

- SwiftPM package, tools-version 5.9, so the code compiles in Swift 5 language mode even with a Swift 6 compiler.
- Release flags are `-Ounchecked -wmo`.
- Minimum macOS is 13. Liquid Glass is guarded by `#if compiler(>=6.2)` plus `if #available(macOS 26.0, *)`. Older SDKs or OSes fall back to `NSVisualEffectView`.
- `Info.plist` sets:
  - `LSUIElement` (no Dock icon, no menu bar item)
  - `NSAppleEventsUsageDescription` (Finder Get Info, Terminal)
- There are no third-party Swift dependencies. Keep it that way.
- Icon: `swift Tools/make-icon.swift icon.png` draws the 1024 px master. `Resources/AppIcon.icns` is made from it with `sips -z` (16–1024, @1x/@2x) into an `.iconset`, then `iconutil -c icns`.

## Architecture

```
Sources/Seek/
  main.swift         entry; `--bench` runs Bench and exits, otherwise NSApplication (accessory policy)
  AppDelegate.swift  wires everything; hotkey; runs SeekCommands. No menu bar item (deliberate: no menu bar bloat).
                     Reopening Seek.app while it runs opens Settings (the way back in if the hotkey fails).
  Config.swift       Config (JSON at ~/.config/seek/config.json, tolerant decoding with defaults)
                     Knowledge (open counts, per-query learning, recents) → ~/Library/Application Support/Seek/knowledge.json
  HotKey.swift       Carbon RegisterEventHotKey (no Accessibility needed); "cmd+shift+space" parser
  Index.swift        foldKey, Snapshot, PathFilter, Store, FileIndex (scan + live updates), IndexCache
  Watcher.swift      FSEvents file-level stream → (path, flags) batches on the index queue
  Matcher.swift      ParsedQuery (filters) + Matcher (scoring, parallel scan, TopK)
  Engine.swift       Item, SearchRequest/Outcome, SearchEngine (index search, browse mode, `in:` via mdfind,
                     mod: filter, learned-result injection)
  Actions.swift      Action enum (titles, SF Symbols, availability) + FileOps (move/copy/rename/zip/…)
  Passwords.swift    PasswordsApp (open + type into search via AX), APW (CLI wrapper), SecureClipboard
  Views.swift        FlippedView, GlassContainer, KeyPanel, Row, Icons, RowView, ResultCell, Chip
  Settings.swift     Settings window: toolbar tabs (General / Index / Passwords), auto-saves on every valid change.
                     HotKeyRecorder (click + press keys), ListEditor (table with +/−), StatusLabel.
                     Launch at Login (SMAppService), Accessibility status/button, apw status/start/pair live here
  SystemSettings.swift  catalogue of System Settings panes (x-apple.systempreferences: ids, keywords)
                     searched by name; results merged among file hits as if they were apps
                     Icons come from each pane's .appex (bundle id → path map built once)
  Launcher.swift     the panel controller (modes, keyboard, layout, preview, buffer) + Toast
  Bench.swift        benchmark
  Demo.swift         `--demo` (README screenshots): gradient backdrop behind the panel, writes panel/window
                     geometry to $SEEK_DEMO_OUT. Used by Tools/screenshots.sh with CFFIXED_USER_HOME=<fake home>
```

### Threads and queues

| Queue | Owns | Notes |
|---|---|---|
| `seek.index` (serial) | `FileIndex`: all `Store` mutation, scanning, FSEvents handling, cache writes | Publishes immutable `Snapshot`s through `onPublish`. |
| `seek.search` (serial, userInteractive) | `SearchEngine`: the current snapshot and the incremental cache | Superseded requests are skipped using a lock-guarded request counter. Results go back to main. |
| main | `Launcher`, `Knowledge`, AppKit | `Knowledge` is main-thread only. Learned hits are computed on main and passed into `SearchRequest`. |

`Snapshot` is a struct of COW arrays, so publishing costs almost nothing. The next mutation on the index queue pays a single copy.

### Index design (the speed story)

- **Columnar `Store`:**
  - `paths: [String]`
  - `keyBytes: [UInt8]`: every match key concatenated
  - `keyStart: [UInt32]` (n+1 entries)
  - `kinds`, `depths`, `alive`, `boosts`
  - `indexOf: [String: Int32]`
- Removal is a tombstone (`alive = false`). `compact()` runs when there are more than 20k dead entries and they make up more than 25% of the store.
- **Match key** = `foldKey(display name)`:
  - ASCII is fast-pathed to lowercase.
  - Other text is case-, diacritic- and width-folded, then NFC-recomposed. This matters for Hangul, which file systems may store decomposed.
  - App keys drop the `.app` suffix.
- **Scan:** `fts_open` with `FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT`, so `d_type` is used and files are never `stat()`ed.
  - Hidden entries are skipped unless `includeHidden` is set.
  - `excludeNames` and `excludePaths` skip whole subtrees.
  - **Packages** (`PathFilter.packageExtensions`: .app, .bundle, .framework, .photoslibrary, .xcodeproj, .pages, …) are indexed as one item and never descended into.
  - Roots themselves aren't indexed, unless the root is a package (e.g. `Finder.app`).
- **Live updates:** FSEvents with `FileEvents | UseCFTypes | NoDefer`, latency 0.3 s.
  - `MustScanSubDirs` → re-walk that subtree.
  - Created, Removed or Renamed → remove the path (and its descendants if it was a folder), then re-add it if it still exists. A directory is re-scanned.
  - A metadata-only change on a path that's already indexed is ignored.
  - Modified or created files are reported through `onTouched` (feeds "recent files").
- **Cache:** `~/Library/Caches/Seek/index.bin` (format `SEEKIDX2`). The header holds a signature string built from roots, excludes and hidden-file settings, so changing the config invalidates the cache. It's loaded at launch for instant results; a full re-walk then builds a fresh `Store` and swaps it in. The cache is saved after each build, 120 s after live changes, and on quit.
- If there's no cache, partial snapshots are published every 50k entries so search works during the first index.

### Matching and ranking

`Matcher.score(term, key)` returns one of these tiers (-1 means no match):

| Match | Score |
|---|---|
| Exact | 1200 |
| Prefix | 1000 |
| Substring starting a word | 800 |
| Substring | 600 |
| Fuzzy subsequence | 300–590 |

How the scoring works:

- **Word boundaries** are space, `-`, `_`, `.`, `(`, `[`, `,`, `/`. camelCase isn't detected, because keys are lowercased.
- **Fuzzy scoring:**
  - +30 for a character that starts a word
  - +12 for a character right after the previous match
  - −gap (capped at 8) otherwise
  - A greedy pass with lookahead prefers a word-start occurrence when the rest of the query can still match after it (`vsc` → Visual Studio Code).
- **Non-ASCII terms only match as substrings**, so a multibyte UTF-8 character never gets split.
- **Multiple terms** (split on spaces) must all match, and the scores are averaged.
- **Final score** = term average + kind boost (app +120, folder +25) + usage boost (min(count, 20) × 12) − key length − depth × 3.
- **Apps first (Alfred-style):** after ranking, `Launcher.appsFirst` moves apps whose name matches at prefix/word-start level (score ≥ 800) above everything else — commands, System Settings panes, learned picks and files — keeping their order. Loose fuzzy app matches stay in place. Not applied in browse mode or `in:` searches. App rows are drawn with a 36 pt icon, a semibold 15 pt title (vertically centred) and an “App” tag, and no location subtitle (⌥↩ still copies the path).
- **The parallel scan** uses `DispatchQueue.concurrentPerform`, one chunk when there are fewer than 16k candidates, otherwise cores × 3 chunks. It keeps a TopK per chunk and merges them.
- **Incremental narrowing:** if the new term bytes start with the previous ones, the filter signature is unchanged and the snapshot generation matches, only the previous match set is rescanned.
- **Learned results:** `Knowledge.learned(for:)` returns up to 3 paths the user picked before for this exact query, or for longer queries that start with it. These are injected at the top if they still exist and still match. Doing this outside the index avoids needing a path→index lookup across queues.

### Query syntax (`ParsedQuery.parse`)

| Syntax | Meaning |
|---|---|
| words | Name terms (fuzzy) |
| `.pdf .key` | Extension filter. A suffix match on the key; implies files only. |
| `app:` `folder:`/`dir:` `file:` | Kind filter. Can be glued to a term (`app:code`). |
| `mod:7d` `mod:12h` `mod:2w` `mod:today` `mod:yesterday` | Modified-since filter. Applied after ranking by `lstat`-ing up to 3,000 top hits; turns off the incremental cache. |
| `in:words…` | Everything after `in:` goes to `mdfind -onlyin ~` (3 s timeout, `~/Library` excluded). |
| a System Settings pane name or keyword (`keyboard`, `wifi`, `dark mode`, `full disk access`; 2+ chars, prefix/word-start) | Opens that pane via `x-apple.systempreferences:`. Up to 4, ranked like apps among file results |
| `settings`, `rebuild index`, `reload settings`, `quit seek` (4+ chars, prefix/word-start match) | `SeekCommand` rows shown above file results |
| text starting with `/` or `~` | **Browse mode.** Lists that directory, filtered by the last path component; folders sort first on ties. |
| `pw <site>` (keyword configurable) | Passwords mode (see below). |

### `seek://` links

Registered in Info.plist; handled in `AppDelegate.handle(_:)`. A `seek://` string passed as a launch argument works too.

| Link | Does |
|---|---|
| `seek://search?q=text[&select=N][&actions=1][&preview=1]` | Shows the panel with that query; optionally selects row N (1-based), opens Actions, or Quick Look |
| `seek://settings[?tab=general\|index\|passwords]` | Opens Settings on that tab |

## UI and behaviour

- **Panel:** a `KeyPanel` (`NSPanel`, borderless + `.nonactivatingPanel`, `canBecomeKey = true`). It takes keyboard focus without activating Seek, so the previous app stays frontmost. It sits at level `.popUpMenu`, joins all Spaces, and hides when it resigns key.
- **Glass:**
  - `GlassContainer` wraps `NSGlassEffectView` (`cornerRadius`, `contentView`) on macOS 26, or a masked `NSVisualEffectView` (`.popover`) otherwise.
  - Collapsed, it's a capsule (radius = bar height / 2 = 30). Expanded, the radius is 26.
  - Content is a `FlippedView` laid out manually with frames in `Launcher.layoutPanel()`. The top edge stays fixed as the panel grows.
- **Look:** a clean Tahoe style.
  - Search field: 22 pt regular, magnifier glyph on the left.
  - Rows: 46 pt, 30 pt icon, 14 pt medium title, 11.5 pt secondary subtitle (location), tertiary `⌘N` badge.
  - Selection: an accent colour at 22% alpha in a rounded rect, with no text colour flip.
  - A footer shows contextual key hints on the left and status ("N results · X ms") on the right.
- **Widths:** 720 normally, plus 400 when the Quick Look pane (`QLPreviewView`) is open. The list area is at least 400 tall with the pane open.
- **Empty query:** shows recents (files opened via Seek plus files FSEvents saw change), newest first.
- **No results:** an info row with filter tips.

### Modes (`Launcher.Mode`)

| Mode | What it does |
|---|---|
| `.search` | Default. Covers normal search, browse mode and Passwords mode. |
| `.actions(Targets)` | → on a result, or ⌥→ on the buffer. Type to filter the actions. |
| `.openWith(Targets)` | Apps from `urlsForApplications(toOpen:)`, with the default app first. |
| `.pickFolder(move:, Targets)` | Destination picker for Move To / Copy To. Searches folders only; browse mode works. Suggests Desktop, Documents, Downloads and Home when the field is empty. Never overwrites: a clash gets "name 2.ext". |
| `.rename(Item)` | The field is pre-filled with the name, base name selected. |

A chip to the left of the field names the current mode. Esc or ← (with an empty field) goes back. Entering a mode saves the search text, and leaving restores it. The buffer clears after its items are acted on.

### Keys (handled in a local `NSEvent` monitor; nothing is handled while an IME is composing)

| Key | Action |
|---|---|
| ↩ | Open (or run the selected row) |
| ⌘↩ | Reveal in Finder. In browse mode on a folder: step into it (same as ⇥) |
| ⌥↩ | Copy the path |
| ↑ ↓, ⌃P ⌃N | Move the selection |
| ⌘1–⌘9 | Activate that row (absolute numbering) |
| → (caret at end) | Actions |
| ⇥ | Complete or browse into the selection (folders, apps, packages get a trailing `/`) |
| Shift tap or ⌘Y | Toggle Quick Look |
| ⌥↑ / ⌥↓ | Add the selection to the buffer, then move |
| ⌥→ | Actions on the buffer |
| ⌥← | Remove the last buffered item |
| ⌥⌫ | Clear the buffer |
| ⌘, | Settings |
| ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z | Text editing in the field (Seek has no Edit menu, so these are handled in the monitor) |
| Esc | Back, close the preview, or hide |
| Click | Activate. Dragging a row drags its file URL out. |

### Actions

Open, Open With…, Reveal in Finder, Quick Look, Copy Path, Copy File, Move To…, Copy To…, Rename…, Move to Trash (`NSWorkspace.recycle`, no confirmation), Open in Terminal, Get Info (AppleScript to Finder), Compress (`ditto` for one item, `zip` for several, then reveal), AirDrop (`NSSharingService`), Show Package Contents (browses into the bundle), Add to Buffer.

A glass Toast capsule at the bottom of the screen confirms each one.

### Passwords

Decision: implement **both** options.

1. **Jump into Passwords (built in).** `pw github` → row "Search Passwords for “github”".
   - It opens `/System/Applications/Passwords.app`.
   - On a background thread it then polls the AX tree for up to 60 s for an `AXTextField` with subrole `AXSearchField`. The wait leaves time for a Touch ID unlock.
   - It focuses the field, sends ⌘A and types the query with `CGEvent.postToPid`.
   - Needs Accessibility permission (Settings → Allow Passwords Integration…).
   - Apple offers no public API or URL scheme for this app.
2. **Inline logins via `apw`** (optional, third party: github.com/bendews/apw, installed through Homebrew). apw talks to iCloud Passwords through the macOS helper the browser extension uses, running a headless browser in a background daemon.
   - **Commands used:**
     - `apw pw list <domain>` (JSON)
     - `apw otp get <domain>`
     - `apw auth` (PIN pairing, interactive)
     - `brew services start apw`
   - **Observed (apw 1.1.1):** output is `{"error": "...", "status": N, "results": [...]}` and the exit code is 0 even on errors. Status 9 = not running/not paired (`"unpaired"`), 3 = no results. `APW.run` maps these.
   - **Browser:** apw runs its *own* headless copy of Chrome/Brave/Edge/Chromium with a separate profile (`~/.apw/browser/<id>`), and copies the iCloud Passwords extension from one of those browsers' profiles. Arc isn't supported, so on the owner's machine the extension was seeded from Arc into `~/.apw/extension` (plus `background.js.orig`) and apw runs headless Brave. Re-seed if the extension updates.
   - **The JSON format isn't documented.** `APW.entries` walks any JSON shape and picks fields by tolerant key names (username/user/usr/login/account/email, password/pwd/pass/secret, domain/site/sites/url/website/host, code/otp/totp/token). For OTP there's a regex fallback for 6–8 digits. **Verify against real output and tighten this.**
   - **Domain heuristic:** a query without a dot gets `.com` appended.
   - **Errors are classified from the output text:**

     | Output contains | Treated as | Row offered |
     |---|---|---|
     | auth, pin, session | needs auth | "Unlock apw", runs `apw auth` in Terminal |
     | daemon, connect, refused, not running | not running | "Start apw" |
     | anything else | failed | the message |

   - **Keys:** ↩ copies the password, ⌘↩ the username, ⌥↩ the 2FA code.
   - **Secret handling:** passwords are never stored in result rows; they're fetched again at copy time. `SecureClipboard` marks them with `org.nspasteboard.ConcealedType` and `TransientType`, and clears the clipboard after 45 s if it hasn't changed. Never log or display secrets.

## Configuration

`~/.config/seek/config.json`. Missing keys fall back to defaults.

| Key | Default |
|---|---|
| `hotkey` | `cmd+shift+space`. This avoids clashing with Alfred's ⌥Space while both are installed. Alert on registration failure. |
| `roots` | `~`, `/Applications`, `/System/Applications`, `/System/Library/CoreServices/Finder.app` |
| `excludeNames` | node_modules, \_\_pycache\_\_, Pods, DerivedData, .build, venv, .venv, bower_components |
| `excludePaths` | `~/Library`, `~/.Trash` |
| `excludePatterns` | `[]`. Regexes matched against a folder's full path; a match skips the folder and everything under it. A leading `~`/`^~` is the home folder. Invalid patterns are logged and ignored. |
| `includeHidden` | false |
| `visibleRows` | 8 |
| `passwordsKeyword` | `pw` |
| `apwPath` | "" (searches /opt/homebrew/bin and /usr/local/bin) |

Edit these in Settings (⌘, in the panel, type “settings”, or reopen Seek.app) or in the JSON file. Saving from Settings, or choosing Reload Settings, re-registers the hotkey and rebuilds the index only if roots, excludes or hidden-file settings changed.

## Risky APIs (check these first when fixing compile or runtime issues)

- **`NSGlassEffectView`** (macOS 26 SDK): only `cornerRadius` and `contentView` are used. Style is left at its default.
- **`QLPreviewView(frame:style:)`** is assumed to be a failable initializer (it's used with `if let`).
- **fts field types:**
  - `fts_pathlen`, `fts_namelen`, `fts_level`, `fts_info` are converted with `Int(...)` / `Int32(...)`.
  - The `fts_open(argv, …)` call passes a `[UnsafeMutablePointer<CChar>?]` array.
- **FSEvents constants** are wrapped in `UInt32(...)`. `FSEventStreamEventId(kFSEventStreamEventIdSinceNow)`.
- **Carbon:**
  - `InstallEventHandler` takes a non-capturing C closure.
  - `RegisterEventHotKey` may *not* fail when another app (e.g. Alfred) already owns the combo, and then both apps fire.
- **Concurrency:** closures that run off the main thread (`onPublish`, `onTouched`) are marked `@Sendable` so they aren't inferred as main-actor isolated. Keep it that way if you move to Swift 6 language mode.
- **Local key monitor + non-activating panel:** the assumption is that key events reach Seek's monitor while the panel is key but the app isn't active. Verify this first. If it fails, override `keyDown` / `performKeyEquivalent` in `KeyPanel` instead.
- **Typing into Passwords:** `CGEvent.postToPid` with `keyboardSetUnicodeString` into the Passwords app. This may need `.cghidEventTap` posting, or setting `kAXValueAttribute`, if the SwiftUI search field ignores per-pid events.
- **Permissions:** ad-hoc signing means TCC (folder access, Accessibility, Automation) resets after each rebuild: Seek stays listed in Accessibility but is no longer trusted, and the system prompt never reappears (remove it with − and re-add). `build.sh` signs with a keychain identity named "Seek Dev" when one exists, which fixes this; `Tools/make-signing-cert.sh` creates it (self-signed, login keychain).
- **Accessibility prompt:** `AXIsProcessTrustedWithOptions(prompt: true)` only prompts once, so the Settings button also opens Privacy & Security → Accessibility. Opening Passwords without access shows a toast and opens that list instead of prompting.

## Ideas not yet built

- A query-specific usage decay (recency weighting) in `Knowledge`.
- A camelCase boundary bitmap for scoring.
- Universal (arm64 + x86_64) builds, a notarized release, and a Homebrew cask.
- An optional fallback row ("Search Passwords for …") when a normal search finds nothing.

## Conventions

- Plain AppKit with manual frame layout, except Auto Layout inside `ResultCell` and the Settings window. No SwiftUI. No dependencies.
- The hot paths (`Matcher.run` / `score`) work on raw `UnsafeBufferPointer<UInt8>`. Don't add allocations or String work inside the per-entry loop.
- All index mutation happens on `FileIndex.queue`. All UI and `Knowledge` work happens on main.
- User-facing strings are short, sentence case, and use typographic quotes.
