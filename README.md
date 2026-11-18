# Seek

A fast, keyboard-first launcher for macOS that finds **apps, folders, files and System Settings**. Think Spotlight or Alfred, but with only the parts you use and none of the waiting.

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
./install.sh                # builds, copies to /Applications and starts Seek
```

Or build a drag-to-Applications disk image with `./build.sh --dmg` (it lands in `build/Seek.dmg`).

The first launch indexes your home folder and apps. macOS will ask whether Seek may access Desktop, Documents and Downloads; allow it. To start Seek automatically, turn on **Open Seek when you log in** in Settings.

Seek has no Dock icon and no menu bar icon. Press the shortcut to open it. The default is **⌘⇧Space**, so you can run Seek alongside Alfred. To use another shortcut, open Settings and record a new one.

### Keeping permissions across rebuilds

macOS ties Accessibility and folder permissions to an app's signature. Without a fixed signing identity, each rebuild looks like a new app and loses them. Create a local identity once, and `build.sh` uses it from then on:

```
Tools/make-signing-cert.sh  # adds a self-signed "Seek Dev" certificate to your login keychain
./install.sh
```

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
| ⌘, | Settings |
| drag a row | Drop the file into any app |
| esc | Back / close |

An empty search shows files you recently opened or changed. Seek learns which result you pick for each query, so the next time you type the same thing, that pick comes first.

### System Settings

Type the name of a settings pane, or something you'd change there, and Seek opens it directly. Each pane appears with its own icon, ranked alongside your apps and files.

| Type | Opens |
|---|---|
| `keyboard`, `key repeat`, `input sources` | Keyboard |
| `displays`, `resolution`, `night shift` | Displays |
| `wifi`, `bluetooth`, `vpn` | Wi-Fi, Bluetooth, VPN |
| `dark mode`, `accent color` | Appearance |
| `dock`, `hot corners`, `stage manager` | Desktop & Dock |
| `full disk access`, `screen recording`, `microphone` | That section of Privacy & Security |

### Seek commands

| Type | Does |
|---|---|
| `settings` | Opens Seek's settings (same as ⌘,) |
| `rebuild index` | Re-scans every folder from scratch |
| `reload settings` | Re-reads `config.json` after you edit it by hand |
| `quit seek` | Quits Seek |

If the shortcut ever stops working, open **Seek.app** again from Finder or Spotlight; that opens Settings.

### Filters

| Filter | Example |
|---|---|
| Extension | `.pdf tax` · `.key .pptx deck` |
| Kind | `app: code` · `folder: proj` · `file: notes` |
| Modified within | `mod:7d report` · `mod:today` · `mod:12h .png` |
| Inside files (Spotlight) | `in: quarterly revenue` |

### Passwords

- `pw github` opens Apple's **Passwords** app already searching for "github". This needs Accessibility permission: in Settings → Passwords, click **Open Accessibility Settings…** and turn Seek on. If Passwords is locked, unlock it with Touch ID and Seek finishes the search.
- **Optional, inline logins** with [apw](https://github.com/bendews/apw). `pw github` then also lists your github.com logins:
  - ↩ copies the password
  - ⌘↩ copies the username
  - ⌥↩ copies the 2FA code

  Passwords are never displayed. They're marked as concealed so clipboard managers skip them, and they're cleared after 45 seconds.

  Setup:
  ```
  brew install bendews/homebrew-tap/apw
  brew services start apw     # or "Start apw" in Settings → Passwords
  apw auth                    # enter the PIN macOS shows; repeat after each restart
  ```
  apw runs its own hidden copy of Chrome, Brave, Edge or Chromium, so one of them must be installed with the [iCloud Passwords extension](https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj). It doesn't touch your everyday browser profile. apw finds logins by website, so search for the site (`pw github`, `pw linear.app`), not the login's name. apw is a third-party tool; read its README before installing.

## Settings

Open Settings with **⌘,** in Seek, or type `settings`. Changes save as you make them.

- **General:** shortcut, visible rows, open at login.
- **Index:** folders to search, and what to skip. Skip folders by name (`node_modules`), by path (`~/Library`), or by a regular expression matched against the full path (`~/Developer/.*/deps$`). You can also include hidden files and rebuild the index here.
- **Passwords:** keyword, Accessibility status, apw status and location.

Everything is stored in `~/.config/seek/config.json`, which you can also edit by hand (then type `reload settings`):

```json
{
  "hotkey": "cmd+shift+space",
  "roots": ["~", "/Applications", "/System/Applications", "/System/Library/CoreServices/Finder.app"],
  "excludeNames": ["node_modules", "__pycache__", "Pods", "DerivedData", ".build", "venv", ".venv", "bower_components"],
  "excludePaths": ["~/Library", "~/.Trash"],
  "excludePatterns": [],
  "includeHidden": false,
  "visibleRows": 8,
  "passwordsKeyword": "pw",
  "apwPath": ""
}
```

## Notes

- Data lives in `~/Library/Application Support/Seek/knowledge.json` (what you open) and `~/Library/Caches/Seek/index.bin` (the index cache).
- No third-party dependencies: plain Swift and AppKit.

## License

[MIT](LICENSE)
