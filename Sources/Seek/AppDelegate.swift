import AppKit

/// No menu bar item: Seek is reached through its hotkey. Settings open with ⌘, in the panel,
/// by typing "settings", or by opening Seek.app again while it's running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private let knowledge = Knowledge()
    private let engine = SearchEngine()
    private var index: FileIndex!
    private var launcher: Launcher!
    private var hotKey: HotKey?
    private let settings = SettingsController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.includeHidden = config.includeHidden
        launcher = Launcher(engine: engine, knowledge: knowledge, config: config)

        index = FileIndex(config: config, usage: knowledge.counts)
        let engine = self.engine
        index.onPublish = { @Sendable [weak self] snapshot in
            engine.update(snapshot)
            DispatchQueue.main.async { self?.launcher.indexChanged() }
        }
        index.onTouched = { @Sendable [weak self] path in
            DispatchQueue.main.async { self?.knowledge.noteTouched(path) }
        }
        launcher.onOpened = { [weak self] item, query in
            guard let self else { return }
            let count = self.knowledge.recordOpen(item.path, query: query)
            self.index.setUsage(item.path, count: count)
        }
        launcher.onCommand = { [weak self] in self?.run($0) }
        settings.onSave = { [weak self] config in self?.apply(config) }
        settings.onRebuildIndex = { [weak self] in self?.run(.rebuildIndex) }
        // Pause the global shortcut while recording a new one, or pressing it would toggle the panel.
        settings.onRecordingHotKey = { [weak self] recording in
            if recording { self?.hotKey = nil } else { self?.registerHotKey() }
        }
        index.rebuild()

        registerHotKey()

        if Demo.enabled { Demo.showBackdrop() }
        for arg in CommandLine.arguments.dropFirst() where arg.hasPrefix("seek://") {
            if let url = URL(string: arg) { DispatchQueue.main.async { self.handle(url) } }
        }
    }

    // MARK: seek:// links

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    /// seek://search?q=text[&select=N][&actions=1][&preview=1]
    /// seek://settings[?tab=general|index|passwords]
    private func handle(_ url: URL) {
        guard url.scheme == "seek" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "search":
            launcher.present(query: value("q") ?? "",
                             select: value("select").flatMap(Int.init),
                             actions: value("actions") == "1",
                             preview: value("preview") == "1")
            if Demo.enabled { Demo.report(frame: self.launcher.panelFrame) }
        case "settings":
            settings.show(Config.load(), tab: value("tab"))
            if Demo.enabled, let n = settings.windowNumber { Demo.report(windowNumber: n) }
        default:
            break
        }
    }

    /// Opening Seek.app while it's already running (Finder, Spotlight, `open`) shows Settings.
    /// This is the way back in if the hotkey ever stops working.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        knowledge.saveNow()
        index.saveCacheNow()
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey = nil
        guard let (code, mods) = HotKey.parse(config.hotkey) else {
            hotKeyProblem("Seek couldn’t understand the hotkey “\(config.hotkey)”.",
                          info: "Use something like “cmd+shift+space” or “option+space”.")
            return
        }
        hotKey = HotKey(keyCode: code, modifiers: mods) { [weak self] in self?.launcher.toggle() }
        if hotKey == nil {
            hotKeyProblem("The shortcut \(config.hotkey) is already taken.",
                          info: "Another app (Alfred?) is using it. Change that app’s hotkey, or pick another one for Seek.")
        }
    }

    private func hotKeyProblem(_ title: String, info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info + "\n\nYou can always reach Settings by opening Seek.app again."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    // MARK: Commands

    private func run(_ command: SeekCommand) {
        switch command {
        case .settings: openSettings()
        case .rebuildIndex: index.rebuild(useCache: false); Toast.shared.show("Rebuilding index…")
        case .reloadSettings: apply(Config.load()); Toast.shared.show("Settings reloaded")
        case .quit: NSApp.terminate(nil)
        }
    }

    private func openSettings() { settings.show(Config.load()) }

    private func apply(_ newConfig: Config) {
        let reindex = PathFilter(config: newConfig).signature != PathFilter(config: config).signature
        let newHotKey = newConfig.hotkey != config.hotkey || hotKey == nil
        config = newConfig
        engine.includeHidden = config.includeHidden
        launcher.config = config
        if newHotKey { registerHotKey() }
        if reindex { index.rebuild(config: config) }
    }
}
