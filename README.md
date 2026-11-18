# Seek

A fast, keyboard-first launcher for macOS that finds **apps, folders and files**. Think Spotlight or Alfred, but with only the parts you use and none of the waiting.

## Why it's fast

- **It keeps its own index in memory.** Seek doesn't send each keystroke to Spotlight's `mds` daemon. It keeps a compact, column-oriented table of names and matches it directly.
- **Matching runs on every core**, over raw UTF-8 bytes. A whole-index scan typically takes a few milliseconds.
- **Typing narrows the search.** Each keystroke that extends the query only rescans the previous matches.
- **The first index walk skips `stat()`.** It uses `fts(3)` with `FTS_NOSTAT`, then keeps up with changes through file-level FSEvents.
- **Startup is instant.** The index is cached on disk and loads at launch, while a background walk catches up.
- **The panel is resident and non-activating.** It opens instantly, and the app you were in stays frontmost.

Measure it on your own Mac:

```
build/Seek.app/Contents/MacOS/Seek --bench saf invoice "read me" .pdf
```

This builds the index from scratch, then times each query in Seek and in `mdfind -name`.

## Build & install

Requires macOS 13+. Liquid Glass needs **macOS 26 and Xcode 26**; older systems get a frosted-glass look instead.

```
xcode-select --install      # if you don't have Xcode or the Command Line Tools
./build.sh
cp -R build/Seek.app /Applications/
open /Applications/Seek.app
```

The first launch indexes your home folder and apps. macOS will ask whether Seek may access Desktop, Documents and Downloads; allow it. Choose **Launch at Login** from the menu bar icon.

The default shortcut is **⌘⇧Space**, so you can run Seek alongside Alfred. To take over Alfred's shortcut, change Alfred's hotkey first, then set `"hotkey": "option+space"` in `~/.config/seek/config.json` and choose **Reload Settings**.

## Using it

| Keys | What it does |
|---|---|
| type | Fuzzy search (`vsc` → Visual Studio Code, `inv 24` → invoice-2024.pdf) |
| ↩ / ⌘↩ / ⌥↩ | Open / Reveal in Finder / Copy path |
| ⌘1…⌘9 | Open that row |
| → | Actions: Open With, Move To, Copy To, Rename, Trash, Compress, AirDrop, Get Info, Terminal… (type to filter) |
| ⇥ | Browse into the selected folder (or type `~/` or `/` to browse from there) |
| ⇧ (tap) or ⌘Y | Quick Look preview pane |
| ⌥↑ / ⌥↓ | Add the selection to the **file buffer** |
| ⌥→ | Run an action on everything in the buffer · ⌥← remove last · ⌥⌫ clear |
| drag a row | Drop the file into any app |
| esc | Back / close |

An empty search shows files you recently opened or changed. Seek learns which result you pick for each query, so the next time you type the same thing, that pick comes first.

### Filters

| Filter | Example |
|---|---|
| Extension | `.pdf tax` · `.key .pptx deck` |
| Kind | `app: code` · `folder: proj` · `file: notes` |
| Modified within | `mod:7d report` · `mod:today` · `mod:12h .png` |
| Inside files (Spotlight) | `in: quarterly revenue` |

### Passwords

- `pw github` opens Apple's **Passwords** app already searching for "github". This needs Accessibility permission (menu bar icon → *Allow Passwords Integration…*). If Passwords is locked, unlock it with Touch ID and Seek finishes the search.
- **Optional, inline logins:** install [apw](https://github.com/bendews/apw) (`brew install bendews/tap/apw`, then `apw start` and `apw auth`). `pw github` then also lists your github.com logins:
  - ↩ copies the password
  - ⌘↩ copies the username
  - ⌥↩ copies the 2FA code

  Passwords are never displayed. They're marked as concealed so clipboard managers skip them, and they're cleared after 45 seconds. apw is a third-party tool that runs a background helper; read its README before installing.

## Settings

`~/.config/seek/config.json`:

```json
{
  "hotkey": "cmd+shift+space",
  "roots": ["~", "/Applications", "/System/Applications", "/System/Library/CoreServices/Finder.app"],
  "excludeNames": ["node_modules", "__pycache__", "Pods", "DerivedData", ".build", "venv", ".venv", "bower_components"],
  "excludePaths": ["~/Library", "~/.Trash"],
  "includeHidden": false,
  "visibleRows": 8,
  "passwordsKeyword": "pw",
  "apwPath": ""
}
```

## Notes

- Seek is ad-hoc signed. After you rebuild it, macOS may ask for folder and Accessibility permission again.
- Data lives in `~/Library/Application Support/Seek/knowledge.json` (what you open) and `~/Library/Caches/Seek/index.bin` (the index cache).
