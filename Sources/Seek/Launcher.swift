import AppKit
import Quartz

/// The search panel: a glass search bar that grows into a result list, with modes for
/// actions, Open With, picking a destination folder, renaming, and Passwords.
final class Launcher: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Targets { var items: [Item]; var fromBuffer: Bool }

    enum Mode {
        case search
        case actions(Targets)
        case openWith(Targets)
        case pickFolder(move: Bool, Targets)
        case rename(Item)
    }

    // Layout
    private let baseWidth: CGFloat = 720
    private let previewWidth: CGFloat = 400
    private let barH: CGFloat = 60
    private let rowH: CGFloat = 46
    private let footerH: CGFloat = 30

    private let engine: SearchEngine
    private let knowledge: Knowledge
    var config: Config
    var onOpened: ((Item, String) -> Void)?
    var onCommand: ((SeekCommand) -> Void)?

    private let panel: KeyPanel
    private let container = GlassContainer(frame: .zero)
    private let leadIcon = NSImageView()
    private let chip = Chip()
    private let field = NSTextField()
    private let bufferStack = NSStackView()
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var preview: QLPreviewView?
    private var previewOn = false
    private var previewWork: DispatchWorkItem?

    private var rows: [Row] = []
    private var mode: Mode = .search
    private var savedQuery = ""
    private var buffer: [Item] = []
    private var openWithApps: [URL] = []
    private var pwGeneration = 0
    private var shiftArmed = false
    private var monitor: Any?
    private var flashWork: DispatchWorkItem?

    private static let numberFormat: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    init(engine: SearchEngine, knowledge: Knowledge, config: Config) {
        self.engine = engine
        self.knowledge = knowledge
        self.config = config
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        buildPanel()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handle(e) ? nil : e
        }
    }

    // MARK: Building

    private func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.delegate = self
        panel.contentView = container

        let content = container.content

        leadIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        leadIcon.contentTintColor = .secondaryLabelColor
        content.addSubview(leadIcon)

        chip.isHidden = true
        content.addSubview(chip)

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        content.addSubview(field)

        bufferStack.orientation = .horizontal
        bufferStack.spacing = 4
        content.addSubview(bufferStack)

        separator.boxType = .separator
        content.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowH
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        content.addSubview(scroll)

        for l in [hintLabel, statusLabel] {
            l.font = .systemFont(ofSize: 11.5)
            l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            content.addSubview(l)
        }
        statusLabel.alignment = .right

        applyModeChrome()
    }

    // MARK: Showing

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        if case .search = mode {} else { exitMode(refresh: false) }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let top = vf.maxY - vf.height * 0.18
        panel.setFrame(NSRect(x: vf.midX - baseWidth / 2, y: top - barH, width: baseWidth, height: barH), display: false)
        layoutPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        refresh()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if previewOn { previewOn = false; preview?.isHidden = true }
        preview?.previewItem = nil
        if case .search = mode {} else { exitMode(refresh: false) }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Called when the index changes; refreshes visible results.
    func indexChanged() {
        guard panel.isVisible, case .search = mode, passwordsQuery(field.stringValue) == nil else { return }
        refresh()
    }

    // MARK: Modes

    private func enter(_ m: Mode) {
        if case .search = mode { savedQuery = field.stringValue }
        mode = m
        switch m {
        case .rename(let item):
            field.stringValue = item.url.lastPathComponent
            if let ed = field.currentEditor() {
                let base = (item.url.lastPathComponent as NSString).deletingPathExtension
                ed.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        default:
            field.stringValue = ""
        }
        applyModeChrome()
        refresh()
    }

    private func exitMode(refresh doRefresh: Bool = true) {
        mode = .search
        field.stringValue = savedQuery
        moveCaretToEnd()
        applyModeChrome()
        if doRefresh { refresh() }
    }

    private func applyModeChrome() {
        var chipText: String?
        var placeholder = "Search apps, files and folders"
        switch mode {
        case .search: break
        case .actions(let t):
            chipText = t.items.count == 1 ? t.items[0].name : "\(t.items.count) items"
            placeholder = "Search actions"
        case .openWith(let t):
            chipText = "Open “\(t.items.count == 1 ? t.items[0].name : "\(t.items.count) items")” with"
            placeholder = "Search apps"
        case .pickFolder(let move, let t):
            chipText = "\(move ? "Move" : "Copy") \(t.items.count == 1 ? "“\(t.items[0].name)”" : "\(t.items.count) items") to"
            placeholder = "Search folders, or type ~/ to browse"
        case .rename:
            chipText = "Rename"
            placeholder = "New name"
        }
        chip.isHidden = chipText == nil
        if let chipText { chip.text = chipText }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        ])
        layoutPanel()
    }

    // MARK: Results

    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func refresh() {
        let text = field.stringValue
        switch mode {
        case .search:
            if let q = passwordsQuery(text) { refreshPasswords(q); return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty { showRecents(); return }
            search(text, foldersOnly: false)

        case .actions(let t):
            var actions = Action.available(for: t.items, buffered: t.fromBuffer)
            let term = foldKey(text.trimmingCharacters(in: .whitespaces))
            if !term.isEmpty {
                let scored = actions.map { ($0, Matcher.scoreAll([term], key: foldKey($0.title))) }.filter { $0.1 >= 0 }
                actions = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
            }
            statusText("")
            setRows(actions.map { Row(title: $0.title, subtitle: "", payload: .action($0), symbol: $0.symbol) })

        case .openWith:
            let term = foldKey(text.trimmingCharacters(in: .whitespaces))
            let rows = openWithApps.compactMap { url -> Row? in
                let name = (url.lastPathComponent as NSString).deletingPathExtension
                if !term.isEmpty && Matcher.scoreAll([term], key: foldKey(name)) < 0 { return nil }
                return Row(title: name, subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                           payload: .openWithApp(url))
            }
            statusText("")
            setRows(rows)

        case .pickFolder:
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                let home = NSHomeDirectory()
                let picks = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 } + [home]
                statusText("Suggested")
                setRows(picks.compactMap(Item.make).map(Row.item))
            } else {
                search(text, foldersOnly: true)
            }

        case .rename(let item):
            statusText("")
            setRows([Row(title: "Rename to “\(text)”", subtitle: item.location, payload: .info, symbol: "pencil")])
        }
    }

    private func search(_ text: String, foldersOnly: Bool) {
        let req = SearchRequest(text: text, foldersOnly: foldersOnly, limit: 60,
                                learned: foldersOnly ? [] : knowledge.learned(for: text))
        let started = mode
        engine.search(req) { [weak self] out in
            guard let self, self.field.stringValue == text, Launcher.sameKind(self.mode, started) else { return }
            var rows = out.items.map(Row.item)
            let commands = foldersOnly ? [] : SeekCommand.matching(text)
            let settings = foldersOnly ? [] : SystemSetting.matching(text)
            if rows.isEmpty && commands.isEmpty && settings.isEmpty {
                if out.contentSearch {
                    rows = [Row(title: "No files contain that", subtitle: "Spotlight content search", payload: .info, symbol: "doc.text.magnifyingglass")]
                } else if !out.indexing {
                    rows = [Row(title: "No results", subtitle: "Tip: in:words searches inside files · .pdf · app: · folder: · mod:7d",
                                payload: .info, symbol: "magnifyingglass")]
                }
            }
            if let dir = out.browsingDirectory {
                self.statusText("\(Launcher.fmt(out.total)) in \((dir as NSString).abbreviatingWithTildeInPath)")
            } else if out.contentSearch {
                self.statusText("\(Launcher.fmt(out.total)) via Spotlight · \(String(format: "%.0f", out.ms)) ms")
            } else if out.indexing && out.indexed == 0 {
                self.statusText("Indexing…")
            } else {
                let suffix = out.indexing ? " · indexing \(Launcher.fmt(out.indexed))…" : ""
                self.statusText("\(Launcher.fmt(out.total)) results · \(String(format: "%.1f", out.ms)) ms\(suffix)")
            }
            rows = Launcher.mergeSettings(settings, into: rows, query: text)
            self.setRows(commands.map(Row.command) + rows)
        }
    }

    private func showRecents() {
        let items = knowledge.recents(limit: config.visibleRows).compactMap(Item.make)
        statusText(items.isEmpty ? "" : "Recent")
        setRows(items.map(Row.item))
    }

    /// Places System Settings matches among file results as if they were apps: each goes above
    /// the first result it outscores (looking at the top few only), otherwise after them.
    static func mergeSettings(_ settings: [(SystemSetting, Int32)], into rows: [Row], query: String) -> [Row] {
        guard !settings.isEmpty else { return rows }
        let terms = query.trimmingCharacters(in: .whitespaces).split(separator: " ").map { foldKey(String($0)) }
        func itemScore(_ r: Row) -> Int32 {
            guard let i = r.item else { return .max }
            let s = Matcher.scoreAll(terms, key: foldKey(i.name))
            if s < 0 { return .max } // learned or content hits we can't compare: keep them on top
            return s + (i.kind == .app ? 120 : i.kind == .folder ? 25 : 0) - Int32(i.name.utf8.count)
        }
        var out = rows
        let window = 6
        for (setting, score) in settings.reversed() {
            let own = score + 120 - Int32(setting.title.utf8.count)
            let limit = min(out.count, window)
            let at = (0..<limit).first { itemScore(out[$0]) < own } ?? limit
            out.insert(.systemSetting(setting), at: at)
        }
        return out
    }

    private static func sameKind(_ a: Mode, _ b: Mode) -> Bool {
        switch (a, b) {
        case (.search, .search), (.pickFolder, .pickFolder): return true
        default: return false
        }
    }

    private static func fmt(_ n: Int) -> String { numberFormat.string(from: NSNumber(value: n)) ?? "\(n)" }

    private func statusText(_ s: String) {
        flashWork?.cancel()
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = s
    }

    /// Shows a short error in the footer.
    private func flash(_ message: String) {
        NSSound.beep()
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.statusLabel.textColor = .tertiaryLabelColor; self?.statusLabel.stringValue = "" }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func setRows(_ newRows: [Row]) {
        rows = newRows
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        layoutPanel()
        updateFooter()
        schedulePreview()
    }

    private var selectedRow: Row? {
        let i = table.selectedRow
        return i >= 0 && i < rows.count ? rows[i] : nil
    }

    // MARK: Passwords

    private func passwordsQuery(_ text: String) -> String? {
        let kw = config.passwordsKeyword.lowercased()
        guard !kw.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower == kw { return "" }
        if lower.hasPrefix(kw + " ") { return String(text.dropFirst(kw.count + 1)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private func refreshPasswords(_ q: String) {
        pwGeneration += 1
        let gen = pwGeneration
        let appRow = Row(title: q.isEmpty ? "Open Passwords" : "Search Passwords for “\(q)”",
                         subtitle: "Apple Passwords app", payload: .passwordsApp(q))
        statusText("Passwords")
        guard let exe = APW.executable(config.apwPath) else { setRows([appRow]); return }
        guard !q.isEmpty else {
            setRows([appRow, Row(title: "Type a site to list your logins", subtitle: "e.g. pw github", payload: .info, symbol: "key")])
            return
        }
        let domain = APW.domain(for: q)
        setRows([appRow, Row(title: "Looking up \(domain)…", subtitle: "apw", payload: .info, symbol: "key")])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.pwGeneration else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = APW.listLogins(exe, domain: domain)
                DispatchQueue.main.async {
                    guard gen == self.pwGeneration, case .search = self.mode else { return }
                    var rows: [Row] = []
                    switch result {
                    case .success(let logins) where logins.isEmpty:
                        rows = [appRow, Row(title: "No saved logins for \(domain)", subtitle: "Try the full domain, e.g. pw accounts.google.com",
                                            payload: .info, symbol: "key")]
                    case .success(let logins):
                        rows = logins.map { Row(title: $0.username, subtitle: $0.domain, payload: .login($0, domain), symbol: "key.fill") }
                        rows.append(appRow)
                    case .failure(.needsAuth):
                        rows = [Row(title: "Unlock apw", subtitle: "Opens Terminal — enter the PIN macOS shows",
                                    payload: .terminal("apw auth"), symbol: "lock.fill"), appRow]
                    case .failure(.notRunning):
                        rows = [Row(title: "Start apw", subtitle: "Runs “brew services start apw” in Terminal",
                                    payload: .terminal("brew services start apw"), symbol: "play.circle"), appRow]
                    case .failure(.notInstalled):
                        rows = [appRow]
                    case .failure(.failed(let msg)):
                        rows = [appRow, Row(title: "apw: \(msg.isEmpty ? "lookup failed" : msg)", subtitle: "", payload: .info, symbol: "exclamationmark.triangle")]
                    }
                    self.setRows(rows)
                }
            }
        }
    }

    private func copyLogin(_ login: Login, domain: String, _ mods: NSEvent.ModifierFlags) {
        guard let exe = APW.executable(config.apwPath) else { return }
        if mods.contains(.command) {
            SecureClipboard.copyPlain(login.username)
            hide()
            Toast.shared.show("Username copied")
            return
        }
        let wantsCode = mods.contains(.option)
        statusText(wantsCode ? "Getting code…" : "Getting password…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = wantsCode ? APW.otp(exe, domain: login.domain.isEmpty ? domain : login.domain)
                                   : APW.password(exe, login: login, queryDomain: domain)
            DispatchQueue.main.async {
                switch result {
                case .success(let secret):
                    SecureClipboard.copy(secret)
                    self.hide()
                    Toast.shared.show(wantsCode ? "Code copied" : "Password copied · clears in 45 s")
                case .failure(.needsAuth):
                    self.flash("apw is locked — run “apw auth”")
                case .failure:
                    self.flash(wantsCode ? "No 2FA code for this login" : "Couldn't get the password")
                }
            }
        }
    }

    // MARK: Running things

    private func activate(_ mods: NSEvent.ModifierFlags) {
        let row = selectedRow
        switch mode {
        case .search:
            guard let row else { return }
            switch row.payload {
            case .item(let item): open(item, mods)
            case .passwordsApp(let q): hide(); PasswordsApp.open(searching: q)
            case .login(let login, let domain): copyLogin(login, domain: domain, mods)
            case .terminal(let cmd): hide(); APW.runInTerminal(cmd)
            case .command(let c): hide(); onCommand?(c)
            case .systemSetting(let s): hide(); s.open()
            default: break
            }

        case .actions(let t):
            guard let row, case .action(let a) = row.payload else { return }
            perform(a, t)

        case .openWith(let t):
            guard let row, case .openWithApp(let app) = row.payload else { return }
            hide()
            NSWorkspace.shared.open(t.items.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            finished(t)

        case .pickFolder(let move, let t):
            guard let folder = row?.item, folder.kind == .folder else { flash("Pick a folder"); return }
            if let err = FileOps.transfer(t.items, to: folder.path, move: move) { flash(err); return }
            hide()
            Toast.shared.show("\(move ? "Moved" : "Copied") to \(folder.name)")
            finished(t)

        case .rename(let item):
            if let err = FileOps.rename(item, to: field.stringValue) { flash(err); return }
            savedQuery = ""
            hide()
            Toast.shared.show("Renamed")
        }
    }

    private func open(_ item: Item, _ mods: NSEvent.ModifierFlags) {
        let query = field.stringValue
        hide()
        if mods.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else if mods.contains(.option) {
            SecureClipboard.copyPlain(item.path)
            Toast.shared.show("Path copied")
        } else {
            NSWorkspace.shared.open(item.url)
        }
        onOpened?(item, query)
    }

    private func perform(_ a: Action, _ t: Targets) {
        let urls = t.items.map(\.url)
        switch a {
        case .open:
            hide()
            for i in t.items { NSWorkspace.shared.open(i.url); onOpened?(i, savedQuery) }
        case .openWith:
            openWithApps = appsToOpen(t.items)
            enter(.openWith(t))
            return
        case .reveal:
            hide(); NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .quickLook:
            exitMode()
            setPreview(true)
            return
        case .copyPath:
            SecureClipboard.copyPlain(t.items.map(\.path).joined(separator: "\n"))
            hide(); Toast.shared.show(t.items.count == 1 ? "Path copied" : "\(t.items.count) paths copied")
        case .copyFile:
            FileOps.copyFiles(t.items)
            hide(); Toast.shared.show("Copied — paste in Finder")
        case .moveTo:
            enter(.pickFolder(move: true, t)); return
        case .copyTo:
            enter(.pickFolder(move: false, t)); return
        case .rename:
            enter(.rename(t.items[0])); return
        case .trash:
            hide()
            NSWorkspace.shared.recycle(urls) { _, error in
                DispatchQueue.main.async { Toast.shared.show(error == nil ? "Moved to Trash" : "Couldn't move to Trash") }
            }
        case .openInTerminal:
            hide(); FileOps.openInTerminal(t.items)
        case .getInfo:
            hide(); FileOps.getInfo(t.items[0])
        case .compress:
            hide(); FileOps.compress(t.items)
        case .airDrop:
            hide(); FileOps.airDrop(t.items)
        case .showPackageContents:
            savedQuery = (t.items[0].path as NSString).abbreviatingWithTildeInPath + "/"
            exitMode()
            return
        case .addToBuffer:
            addToBuffer(t.items)
            exitMode()
            return
        }
        finished(t)
    }

    /// Clears the buffer once its items have been acted on.
    private func finished(_ t: Targets) {
        if t.fromBuffer { buffer.removeAll(); updateBuffer() }
    }

    private func appsToOpen(_ items: [Item]) -> [URL] {
        guard let first = items.first else { return [] }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        if let def = NSWorkspace.shared.urlForApplication(toOpen: first.url) {
            apps.removeAll { $0 == def }
            apps.insert(def, at: 0)
        }
        return apps
    }

    private func openActions(_ items: [Item], fromBuffer: Bool) {
        guard !items.isEmpty else { return }
        enter(.actions(Targets(items: items, fromBuffer: fromBuffer)))
    }

    // MARK: Buffer

    private func addToBuffer(_ items: [Item]) {
        for i in items where !buffer.contains(i) { buffer.append(i) }
        updateBuffer()
    }

    private func updateBuffer() {
        bufferStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in buffer.suffix(5) {
            let v = NSImageView(image: Icons.icon(for: item))
            v.toolTip = item.path
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 24).isActive = true
            v.heightAnchor.constraint(equalToConstant: 24).isActive = true
            bufferStack.addArrangedSubview(v)
        }
        if buffer.count > 5 {
            let more = NSTextField(labelWithString: "+\(buffer.count - 5)")
            more.font = .systemFont(ofSize: 12, weight: .semibold)
            more.textColor = .secondaryLabelColor
            bufferStack.addArrangedSubview(more)
        }
        layoutPanel()
        updateFooter()
    }

    private var bufferWidth: CGFloat {
        if buffer.isEmpty { return 0 }
        return CGFloat(min(buffer.count, 5)) * 28 + (buffer.count > 5 ? 30 : 0)
    }

    // MARK: Preview

    private func setPreview(_ on: Bool) {
        previewOn = on
        if on && preview == nil, let pv = QLPreviewView(frame: .zero, style: .normal) {
            pv.shouldCloseWithWindow = false
            pv.wantsLayer = true
            pv.layer?.cornerRadius = 16
            pv.layer?.masksToBounds = true
            container.content.addSubview(pv)
            preview = pv
        }
        preview?.isHidden = !on
        if !on { preview?.previewItem = nil }
        layoutPanel()
        updatePreviewItem()
    }

    private func schedulePreview() {
        guard previewOn else { return }
        previewWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.updatePreviewItem() }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: w)
    }

    private func updatePreviewItem() {
        guard previewOn, let pv = preview else { return }
        let url = selectedRow?.item?.url
        if (pv.previewItem as? NSURL)?.path != url?.path { pv.previewItem = url as NSURL? }
    }

    // MARK: Keyboard

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    private var caretAtEnd: Bool {
        guard let ed = field.currentEditor() else { return true }
        return ed.selectedRange.location == (ed.string as NSString).length && ed.selectedRange.length == 0
    }

    private var caretAtStart: Bool {
        guard let ed = field.currentEditor() else { return true }
        return ed.selectedRange.location == 0 && ed.selectedRange.length == 0
    }

    /// Returns true if the event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])

        if e.type == .flagsChanged {
            // A lone tap of Shift toggles Quick Look, like Alfred.
            if mods == .shift { shiftArmed = true }
            else if mods.isEmpty && shiftArmed { shiftArmed = false; togglePreview() }
            else { shiftArmed = false }
            return false
        }
        shiftArmed = false
        if isComposing { return false } // let the input method (e.g. Korean) finish first

        switch e.keyCode {
        case 36, 76: // return
            activate(mods)
            return true
        case 125, 126: // down, up
            let delta = e.keyCode == 125 ? 1 : -1
            if mods == .option, case .search = mode, let item = selectedRow?.item {
                addToBuffer([item])
            }
            move(delta)
            return true
        case 45 where mods == .control: move(1); return true  // ⌃N
        case 35 where mods == .control: move(-1); return true // ⌃P
        case 124: // right
            if mods == .option, !buffer.isEmpty, case .search = mode {
                openActions(buffer, fromBuffer: true)
                return true
            }
            guard mods.isEmpty, caretAtEnd else { return false }
            switch mode {
            case .search:
                if let item = selectedRow?.item { openActions([item], fromBuffer: false); return true }
            case .actions(let t):
                if case .action(.openWith)? = selectedRow?.payload { perform(.openWith, t); return true }
            default: break
            }
            return false
        case 123: // left
            if mods == .option, !buffer.isEmpty, case .search = mode {
                buffer.removeLast()
                updateBuffer()
                return true
            }
            if mods.isEmpty, caretAtStart || field.stringValue.isEmpty {
                switch mode {
                case .actions, .openWith: exitMode(); return true
                default: break
                }
            }
            return false
        case 48: // tab
            tabComplete()
            return true
        case 53: // escape
            escape()
            return true
        case 51 where mods == .option && !buffer.isEmpty: // ⌥⌫ clears the buffer
            buffer.removeAll()
            updateBuffer()
            return true
        case 43 where mods == .command: // ⌘, opens Settings
            hide()
            onCommand?(.settings)
            return true
        case 16 where mods == .command: // ⌘Y
            togglePreview()
            return true
        default:
            if mods == .command, let n = Launcher.digitKeys[e.keyCode] {
                let i = n - 1
                if i < rows.count {
                    table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                    activate([])
                }
                return true
            }
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let i = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func tabComplete() {
        guard let item = selectedRow?.item else { return }
        switch mode {
        case .search, .pickFolder: break
        default: return
        }
        let path = (item.path as NSString).abbreviatingWithTildeInPath
        let descend = item.kind == .folder || item.kind == .app || PathFilter.isPackage(item.path)
        field.stringValue = descend ? path + "/" : path
        moveCaretToEnd()
        refresh()
    }

    private func escape() {
        switch mode {
        case .search:
            if previewOn { setPreview(false) } else { hide() }
        default:
            exitMode()
        }
    }

    private func togglePreview() {
        guard case .search = mode else { return }
        setPreview(!previewOn)
    }

    private func moveCaretToEnd() {
        if let ed = field.currentEditor() {
            ed.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        activate(NSEvent.modifierFlags.intersection([.command, .option]))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ResultCell) ?? {
            let c = ResultCell(frame: .zero)
            c.identifier = id
            return c
        }()
        cell.configure(rows[row], badge: row < 9 ? "⌘\(row + 1)" : "")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        schedulePreview()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows[row].item.map { $0.url as NSURL }
    }

    // MARK: Layout

    private func layoutPanel() {
        let shown = min(rows.count, config.visibleRows)
        let expanded = shown > 0 || previewOn
        let width = baseWidth + (previewOn ? previewWidth : 0)
        var listH = CGFloat(shown) * rowH
        if previewOn { listH = max(listH, 400) }
        let listTop = barH + 1 + 8
        let height = expanded ? listTop + listH + 4 + footerH : barH

        var f = panel.frame
        let top = f.maxY, midX = f.midX
        f.size = NSSize(width: width, height: height)
        f.origin = NSPoint(x: (midX - width / 2).rounded(), y: top - height)
        if f != panel.frame { panel.setFrame(f, display: true) }
        container.cornerRadius = expanded ? 26 : barH / 2
        container.displayIfNeeded()
        panel.invalidateShadow()

        let cy = barH / 2
        var x: CGFloat = 22
        leadIcon.frame = NSRect(x: x, y: cy - 11, width: 22, height: 22)
        x += 34
        if !chip.isHidden {
            let w = min(chip.fittingWidth, 300)
            chip.frame = NSRect(x: x, y: cy - 12, width: w, height: 24)
            x += w + 10
        }
        let bw = bufferWidth
        bufferStack.frame = NSRect(x: width - 22 - bw, y: cy - 12, width: bw, height: 24)
        bufferStack.isHidden = bw == 0
        field.frame = NSRect(x: x, y: cy - 15, width: max(80, width - x - 24 - (bw > 0 ? bw + 12 : 0)), height: 30)

        separator.isHidden = !expanded
        separator.frame = NSRect(x: 20, y: barH, width: width - 40, height: 1)

        let listW = previewOn ? baseWidth : width
        scroll.isHidden = !expanded
        scroll.frame = NSRect(x: 0, y: listTop, width: listW, height: listH)
        table.tableColumns.first?.width = listW
        preview?.frame = NSRect(x: listW, y: listTop + 4, width: previewWidth - 16, height: listH - 8)

        hintLabel.isHidden = !expanded
        statusLabel.isHidden = !expanded
        let fy = height - footerH + 7
        statusLabel.frame = NSRect(x: width - 22 - 280, y: fy, width: 280, height: 16)
        hintLabel.frame = NSRect(x: 22, y: fy, width: width - 22 - 300, height: 16)
    }

    private func updateFooter() {
        var hint = ""
        switch mode {
        case .search:
            switch selectedRow?.payload {
            case .item(let i)?:
                hint = "↩ Open   ⌘↩ Reveal   ⌥↩ Copy Path   → Actions"
                    + (i.kind == .file && !PathFilter.isPackage(i.path) ? "" : "   ⇥ Browse") + "   ⇧ Preview"
            case .login?: hint = "↩ Copy Password   ⌘↩ Copy Username   ⌥↩ Copy 2FA Code"
            case .passwordsApp?: hint = "↩ Open in Passwords"
            case .terminal?: hint = "↩ Run in Terminal"
            case .command?: hint = "↩ Run   ⌘, Settings"
            case .systemSetting?: hint = "↩ Open in System Settings"
            default: break
            }
            if !buffer.isEmpty { hint += "   ⌥→ Act on \(buffer.count) buffered" }
        case .actions: hint = "↩ Run   ← Back   Type to filter"
        case .openWith: hint = "↩ Open   ← Back"
        case .pickFolder(let move, _): hint = (move ? "↩ Move Here" : "↩ Copy Here") + "   ⇥ Browse Into   esc Cancel"
        case .rename: hint = "↩ Rename   esc Cancel"
        }
        hintLabel.stringValue = hint
    }
}

/// A small glass capsule at the bottom of the screen confirming an action.
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private let container = GlassContainer(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.contentView = container
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            container.content.addSubview(label)
            panel = p
            return p
        }()
        label.stringValue = text
        let size = label.intrinsicContentSize
        let w = ceil(size.width) + 40, h: CGFloat = 40
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrame(NSRect(x: vf.midX - w / 2, y: vf.minY + 90, width: w, height: h), display: true)
        container.cornerRadius = h / 2
        container.displayIfNeeded()
        p.invalidateShadow()
        label.frame = NSRect(x: 20, y: (h - size.height) / 2, width: ceil(size.width) + 2, height: size.height)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p?.animator().alphaValue = 0 },
                                                 completionHandler: { p?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

/// Seek's own commands, offered as results when the query matches them ("settings", "quit", …).
/// Seek has no menu bar item; these are how you reach it besides ⌘, (Settings).
enum SeekCommand: CaseIterable {
    case settings, rebuildIndex, reloadSettings, quit

    var title: String {
        switch self {
        case .settings: return "Seek Settings"
        case .rebuildIndex: return "Rebuild Seek Index"
        case .reloadSettings: return "Reload Seek Settings"
        case .quit: return "Quit Seek"
        }
    }

    var subtitle: String {
        switch self {
        case .settings: return "Hotkey, folders, skip lists · ⌘,"
        case .rebuildIndex: return "Re-scan every folder from scratch"
        case .reloadSettings: return "Re-read ~/.config/seek/config.json"
        case .quit: return "Stop Seek until you open it again"
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .rebuildIndex: return "arrow.clockwise"
        case .reloadSettings: return "doc.badge.gearshape"
        case .quit: return "power"
        }
    }

    /// Names the command answers to, besides its title.
    private var keywords: [String] {
        switch self {
        case .settings: return ["settings", "preferences", "seek settings"]
        case .rebuildIndex: return ["rebuild index", "reindex", "seek rebuild"]
        case .reloadSettings: return ["reload settings", "seek reload"]
        case .quit: return ["quit seek", "exit seek"]
        }
    }

    /// Commands whose name starts with (or has a word starting with) the query. Needs 4+ characters
    /// so short searches ("con", "pre") aren't crowded by commands.
    static func matching(_ text: String) -> [SeekCommand] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 4, let first = q.first, !"/~.".contains(first), !q.contains(":") else { return [] }
        let terms = q.split(separator: " ").map { foldKey(String($0)) }
        var hits: [(SeekCommand, Int32)] = []
        for c in allCases {
            let best = ([c.title] + c.keywords).map { Matcher.scoreAll(terms, key: foldKey($0)) }.max() ?? -1
            if best >= 800 { hits.append((c, best)) }
        }
        return hits.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension Row {
    static func command(_ c: SeekCommand) -> Row {
        Row(title: c.title, subtitle: c.subtitle, payload: .command(c), symbol: c.symbol)
    }
}
