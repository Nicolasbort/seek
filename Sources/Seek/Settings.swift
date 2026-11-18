import AppKit
import ServiceManagement

// MARK: - Window

/// Seek is an accessory app with no Edit menu, so the settings window handles ⌘X/C/V/A/Z/W itself.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch (key, mods.contains(.shift)) {
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true):  action = Selector(("redo:"))
            case ("w", false): action = #selector(NSWindow.performClose(_:))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Controller

/// Settings with toolbar tabs. Every change is validated and saved right away (no Save button).
final class SettingsController: NSObject, NSWindowDelegate {
    /// Called with the new config after each successful save.
    var onSave: ((Config) -> Void)?
    /// Called while the hotkey recorder is listening, so the global hotkey can be paused.
    var onRecordingHotKey: ((Bool) -> Void)?
    var onRebuildIndex: (() -> Void)?

    private var window: SettingsWindow?
    private var tabs: NSTabViewController?
    private var config = Config()
    private var saveWork: DispatchWorkItem?
    private var statusTimer: Timer?

    // General
    private let hotkey = HotKeyRecorder()
    private let rowsField = NSTextField()
    private let rowsStepper = NSStepper()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Open Seek when you log in", target: nil, action: nil)
    private let generalError = SettingsController.errorLabel()
    // Index
    private let roots = ListEditor(placeholder: "Folder", picksFolders: true)
    private let excludeNames = ListEditor(placeholder: "Folder name, e.g. node_modules", picksFolders: false)
    private let excludePaths = ListEditor(placeholder: "Folder", picksFolders: true)
    private let excludePatterns = ListEditor(placeholder: "Regular expression", picksFolders: false, monospaced: true)
    private let includeHidden = NSButton(checkboxWithTitle: "Include hidden files and folders", target: nil, action: nil)
    private let indexError = SettingsController.errorLabel()
    // Passwords
    private let keyword = NSTextField()
    private let axStatus = StatusLabel()
    private let apwStatus = StatusLabel()
    private let apwPath = NSTextField()
    private let passwordsError = SettingsController.errorLabel()

    /// The settings window, for demo screenshots.
    var windowNumber: Int? { window?.windowNumber }

    func show(_ config: Config, tab: String? = nil) {
        self.config = config
        if window == nil { build() }
        if let tab, let tabs,
           let i = tabs.tabViewItems.firstIndex(where: { $0.label.lowercased() == tab.lowercased() }) {
            tabs.selectedTabViewItemIndex = i
        }
        fill()
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        hotkey.stopRecording()
        flushSave()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshStatus() }

    // MARK: Building

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for (title, symbol, view) in [("General", "gearshape", generalPane()),
                                      ("Index", "folder", indexPane()),
                                      ("Passwords", "key", passwordsPane())] {
            let vc = PaneController(content: view)
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        self.tabs = tabs
        let w = SettingsWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
    }

    private func generalPane() -> NSView {
        hotkey.onChange = { [weak self] value in self?.config.hotkey = value; self?.changed() }
        hotkey.onRecording = { [weak self] on in self?.onRecordingHotKey?(on) }

        rowsField.alignment = .right
        rowsField.formatter = {
            let f = NumberFormatter(); f.minimum = 1; f.maximum = 30; f.allowsFloats = false; return f
        }()
        rowsField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        rowsField.target = self
        rowsField.action = #selector(rowsTyped)
        rowsStepper.minValue = 1
        rowsStepper.maxValue = 30
        rowsStepper.target = self
        rowsStepper.action = #selector(stepped)
        let rows = NSStackView(views: [rowsField, rowsStepper, SettingsController.secondary("rows before the list scrolls")])
        rows.spacing = 6

        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLogin)

        let grid = NSGridView(views: [
            [label("Shortcut:"), hotkey],
            [empty(), hint("Click, then press the keys you want. Esc cancels.")],
            [label("Results:"), rows],
            [label("Startup:"), launchAtLogin],
        ])
        styleGrid(grid)
        let footer = hint("Open these settings with ⌘, in Seek, by typing “settings”, or by opening Seek.app again.")
        return stack([grid, footer, generalError])
    }

    private func indexPane() -> NSView {
        for l in [roots, excludeNames, excludePaths, excludePatterns] {
            l.onChange = { [weak self] in self?.listsChanged() }
            l.heightAnchor.constraint(equalToConstant: 104).isActive = true
        }
        includeHidden.target = self
        includeHidden.action = #selector(hiddenToggled)
        let rebuild = NSButton(title: "Rebuild Index", target: self, action: #selector(rebuildIndex))

        let grid = NSGridView(views: [
            [label("Search in:"), roots],
            [label("Skip folders named:"), excludeNames],
            [label("Skip folders:"), excludePaths],
            [label("Skip paths matching:"), excludePatterns],
            [empty(), hint("Regular expressions checked against each folder’s full path. A leading ~ is your home folder, e.g. ~/Developer/.*/deps$")],
            [empty(), includeHidden],
            [empty(), rebuild],
        ])
        styleGrid(grid)
        for i in 0..<4 { grid.cell(atColumnIndex: 0, rowIndex: i).yPlacement = .top }
        for i in 0..<4 { grid.row(at: i).rowAlignment = .none }
        return stack([grid, indexError])
    }

    private func passwordsPane() -> NSView {
        keyword.placeholderString = "pw"
        keyword.target = self
        keyword.action = #selector(textEdited)
        keyword.delegate = self
        keyword.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let keywordRow = NSStackView(views: [keyword, SettingsController.secondary("then a site, e.g. “pw github”")])
        keywordRow.spacing = 8

        let openAX = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(allowPasswords))
        let axRow = NSStackView(views: [axStatus, openAX])
        axRow.orientation = .vertical
        axRow.alignment = .leading
        axRow.spacing = 6

        apwPath.placeholderString = "Find automatically"
        apwPath.target = self
        apwPath.action = #selector(textEdited)
        apwPath.delegate = self
        let start = NSButton(title: "Start apw", target: self, action: #selector(startAPW))
        let pair = NSButton(title: "Pair with Passwords…", target: self, action: #selector(pairAPW))
        let apwButtons = NSStackView(views: [start, pair])
        apwButtons.spacing = 8
        let apwRow = NSStackView(views: [apwStatus, apwButtons])
        apwRow.orientation = .vertical
        apwRow.alignment = .leading
        apwRow.spacing = 6

        let grid = NSGridView(views: [
            [label("Keyword:"), keywordRow],
            [label("Passwords app:"), axRow],
            [empty(), hint("Seek opens Passwords and types your search. It needs Accessibility access: turn Seek on in the list. If Seek is already there, remove it with − and add it again.")],
            [label("Inline logins:"), apwRow],
            [label("apw location:"), apwPath],
            [empty(), hint("Lists logins right in Seek using apw. It needs Chrome, Brave or Edge with the iCloud Passwords extension. Pair once after each restart.")],
        ])
        styleGrid(grid)
        grid.cell(atColumnIndex: 0, rowIndex: 1).yPlacement = .top
        grid.cell(atColumnIndex: 0, rowIndex: 3).yPlacement = .top
        grid.row(at: 1).rowAlignment = .none
        grid.row(at: 3).rowAlignment = .none
        return stack([grid, passwordsError])
    }

    // MARK: Layout helpers

    private func stack(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 14
        s.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -56).isActive = true }
        s.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return s
    }

    private func styleGrid(_ g: NSGridView) {
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.rowAlignment = .firstBaseline
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 150
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func hint(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private static func secondary(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private static func errorLabel() -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        l.textColor = .systemRed
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.isHidden = true
        return l
    }

    private func empty() -> NSView { NSGridCell.emptyContentView }

    // MARK: Values

    private func fill() {
        hotkey.value = config.hotkey
        rowsField.integerValue = config.visibleRows
        rowsStepper.integerValue = config.visibleRows
        includeHidden.state = config.includeHidden ? .on : .off
        keyword.stringValue = config.passwordsKeyword
        apwPath.stringValue = config.apwPath
        roots.items = config.roots
        excludeNames.items = config.excludeNames
        excludePaths.items = config.excludePaths
        excludePatterns.items = config.excludePatterns
        for l in [generalError, indexError, passwordsError] { show(l, "") }
    }

    private func refreshStatus() {
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if PasswordsApp.ensureAccessibility(prompt: false) {
            axStatus.set(.ok, "Accessibility access allowed")
        } else {
            axStatus.set(.bad, "Accessibility access not allowed")
        }
        if let exe = APW.executable(config.apwPath) {
            apwStatus.set(.ok, "apw found at \((exe as NSString).abbreviatingWithTildeInPath)")
        } else {
            apwStatus.set(.off, "apw isn’t installed (brew install bendews/homebrew-tap/apw)")
        }
    }

    private func show(_ label: NSTextField, _ text: String) {
        label.stringValue = text
        label.isHidden = text.isEmpty
    }

    /// Validates the current config, shows problems next to the controls, and saves if it's valid.
    private func changed() {
        var general: [String] = [], index: [String] = [], passwords: [String] = []
        if HotKey.parse(config.hotkey) == nil { general.append("Seek doesn’t understand the shortcut “\(config.hotkey)”.") }
        if config.roots.isEmpty { index.append("Add at least one folder to search in.") }
        for p in config.excludePatterns where PathFilter.compile(p) == nil {
            index.append("“\(p)” isn’t a valid regular expression.")
        }
        if config.passwordsKeyword.isEmpty || config.passwordsKeyword.contains(" ") {
            passwords.append("The keyword must be one word.")
        }
        show(generalError, general.joined(separator: "\n"))
        show(indexError, index.joined(separator: "\n"))
        show(passwordsError, passwords.joined(separator: "\n"))
        guard general.isEmpty && index.isEmpty && passwords.isEmpty else { return }

        // Short delay so several quick edits (adding folders) cause one save and one re-index.
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func flushSave() {
        guard let w = saveWork, !w.isCancelled else { return }
        w.cancel()
        save()
    }

    private func save() {
        saveWork = nil
        do {
            try config.save()
            onSave?(config)
        } catch {
            show(generalError, "Couldn’t save settings: \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    @objc private func stepped() {
        rowsField.integerValue = rowsStepper.integerValue
        config.visibleRows = rowsStepper.integerValue
        changed()
    }

    @objc private func rowsTyped() {
        let n = max(1, min(30, rowsField.integerValue))
        rowsStepper.integerValue = n
        config.visibleRows = n
        changed()
    }

    @objc private func hiddenToggled() {
        config.includeHidden = includeHidden.state == .on
        changed()
    }

    @objc private func textEdited() {
        config.passwordsKeyword = keyword.stringValue.trimmingCharacters(in: .whitespaces)
        config.apwPath = apwPath.stringValue.trimmingCharacters(in: .whitespaces)
        refreshStatus()
        changed()
    }

    private func listsChanged() {
        config.roots = roots.items
        config.excludeNames = excludeNames.items
        config.excludePaths = excludePaths.items
        config.excludePatterns = excludePatterns.items
        changed()
    }

    @objc private func rebuildIndex() {
        flushSave()
        onRebuildIndex?()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            show(generalError, "")
        } catch {
            show(generalError, "Couldn’t change the login item: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    @objc private func allowPasswords() {
        // Registers Seek in the list (and shows the system prompt the first time)...
        _ = PasswordsApp.ensureAccessibility(prompt: true)
        // ...and opens the list, since the prompt never comes back once Seek has been listed.
        SystemSetting.all.first { $0.anchor == "Privacy_Accessibility" }?.open()
    }

    @objc private func startAPW() { APW.runInTerminal("brew services start apw") }
    @objc private func pairAPW() { APW.runInTerminal("apw auth") }
}

extension SettingsController: NSTextFieldDelegate {
    /// Saves text fields as you type, not just on Return.
    func controlTextDidChange(_ obj: Notification) { textEdited() }
}

/// Hosts one settings pane and sizes the window to it.
private final class PaneController: NSViewController {
    private let content: NSView
    init(content: NSView) { self.content = content; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = content
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }
}

// MARK: - Status label

/// A coloured dot and a line of text.
final class StatusLabel: NSStackView {
    enum State { case ok, bad, off }
    private let dot = NSImageView()
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        spacing = 6
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        addArrangedSubview(dot)
        addArrangedSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ state: State, _ s: String) {
        text.stringValue = s
        switch state {
        case .ok: dot.contentTintColor = .systemGreen
        case .bad: dot.contentTintColor = .systemOrange
        case .off: dot.contentTintColor = .tertiaryLabelColor
        }
    }
}

// MARK: - Hotkey recorder

/// A button that records a shortcut: click it, press keys. Produces strings HotKey.parse reads.
final class HotKeyRecorder: NSButton {
    var onChange: ((String) -> Void)?
    var onRecording: ((Bool) -> Void)?
    var value = "" { didSet { if !recording { title = HotKeyRecorder.pretty(value) } } }

    private var recording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        recording = true
        title = "Type shortcut…"
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, self.recording else { return e }
            if e.type == .flagsChanged {
                let live = HotKeyRecorder.modifierSymbols(e.modifierFlags)
                self.title = live.isEmpty ? "Type shortcut…" : live
                return nil
            }
            self.record(e)
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        title = HotKeyRecorder.pretty(value)
        onRecording?(false)
    }

    @objc private func windowResigned() { stopRecording() }

    private func record(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 53 && flags.isEmpty { stopRecording(); return } // esc cancels
        guard let key = HotKeyRecorder.keyName(e.keyCode) else { NSSound.beep(); return }
        let isFunctionKey = key.hasPrefix("f") && key.count > 1
        guard !flags.isEmpty || isFunctionKey else { NSSound.beep(); return } // a bare letter would be typed everywhere
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(key)
        value = parts.joined(separator: "+")
        stopRecording()
        onChange?(value)
    }

    private static func keyName(_ code: UInt16) -> String? {
        let names = HotKey.keyCodes.filter { $0.value == UInt32(code) }.map(\.key)
        // Prefer the canonical spelling where there are aliases (return/enter, escape/esc).
        return names.first { $0 == "return" || $0 == "escape" } ?? names.min()
    }

    private static func modifierSymbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "")
            + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }

    /// "cmd+shift+space" → "⇧⌘ Space"
    static func pretty(_ s: String) -> String {
        var mods = "", key = ""
        for raw in s.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": mods += "⌘"
            case "opt", "option", "alt", "⌥": mods += "⌥"
            case "ctrl", "control", "⌃": mods += "⌃"
            case "shift", "⇧": mods += "⇧"
            case let k: key = k.count == 1 ? k.uppercased() : k.capitalized
            }
        }
        // Order like macOS menus: ⌃⌥⇧⌘
        let ordered = ["⌃", "⌥", "⇧", "⌘"].filter { mods.contains($0) }.joined()
        if key.isEmpty { return s.isEmpty ? "None" : s }
        return ordered + " " + key
    }
}

// MARK: - List editor

/// A bordered one-column list with + / − buttons underneath, like the lists in System Settings.
/// Folder lists add through an open panel; text lists add an empty row and start editing it.
final class ListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    var items: [String] = [] { didSet { table.reloadData() } }

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let buttons = NSSegmentedControl()
    private let placeholder: String
    private let picksFolders: Bool
    private let monospaced: Bool

    init(placeholder: String, picksFolders: Bool, monospaced: Bool = false) {
        self.placeholder = placeholder
        self.picksFolders = picksFolders
        self.monospaced = monospaced
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        buttons.segmentStyle = .smallSquare
        buttons.trackingMode = .momentary
        buttons.segmentCount = 2
        buttons.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        buttons.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        buttons.setWidth(24, forSegment: 0)
        buttons.setWidth(24, forSegment: 1)
        buttons.target = self
        buttons.action = #selector(buttonClicked)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -1),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Align the list's top with its label's first line.
    override var firstBaselineOffsetFromTop: CGFloat { 16 }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let f = NSTextField()
            f.isBordered = false
            f.drawsBackground = false
            f.lineBreakMode = .byTruncatingMiddle
            f.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
            f.placeholderString = placeholder
            f.isEditable = !picksFolders
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = items[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard row >= 0, row < items.count else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { items.remove(at: row) } else { items[row] = text }
        onChange?()
    }

    @objc private func editClicked() {
        let row = table.clickedRow
        guard !picksFolders, row >= 0 else { return }
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func buttonClicked() {
        if buttons.selectedSegment == 0 { add() } else { removeSelected() }
    }

    private func updateButtons() { buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1) }

    private func add() {
        guard picksFolders else {
            items.append("")
            let row = items.count - 1
            table.scrollRowToVisible(row)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.editColumn(0, row: row, with: nil, select: true)
            return
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let home = NSHomeDirectory()
            for url in panel.urls {
                var p = url.path
                if p == home { p = "~" } else if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
                if !self.items.contains(p) { self.items.append(p) }
            }
            self.onChange?()
        }
    }

    private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        window?.makeFirstResponder(table) // ends any edit first
        items = items.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        updateButtons()
        onChange?()
    }
}
