import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private let knowledge = Knowledge()
    private let engine = SearchEngine()
    private var index: FileIndex!
    private var launcher: Launcher!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!

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
        index.rebuild()

        registerHotKey()
        buildStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        knowledge.saveNow()
        index.saveCacheNow()
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey = nil
        guard let (code, mods) = HotKey.parse(config.hotkey) else {
            alert("Seek couldn't understand the hotkey “\(config.hotkey)”.",
                  info: "Use something like \"cmd+shift+space\" or \"option+space\" in \(Config.url.path).")
            return
        }
        hotKey = HotKey(keyCode: code, modifiers: mods) { [weak self] in self?.launcher.toggle() }
        if hotKey == nil {
            alert("The shortcut \(config.hotkey) is already taken.",
                  info: "Another app (Alfred?) is using it. Change Alfred's hotkey, or set \"hotkey\" in \(Config.url.path) and choose Reload Settings.")
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Seek")

        let menu = NSMenu()
        menu.addItem(item("Open Seek", #selector(openLauncher)))
        menu.addItem(.separator())
        menu.addItem(item("Rebuild Index", #selector(rebuildIndex)))
        menu.addItem(item("Edit Settings…", #selector(editSettings)))
        menu.addItem(item("Reload Settings", #selector(reloadSettings)))
        menu.addItem(item("Allow Passwords Integration…", #selector(requestAccessibility)))
        loginItem = item("Launch at Login", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Seek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openLauncher() { launcher.show() }

    @objc private func rebuildIndex() { index.rebuild(useCache: false) }

    @objc private func editSettings() {
        _ = Config.load() // makes sure the file exists
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([Config.url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reloadSettings() {
        config = Config.load()
        engine.includeHidden = config.includeHidden
        launcher.config = config
        registerHotKey()
        index.rebuild(config: config)
    }

    @objc private func requestAccessibility() {
        if PasswordsApp.ensureAccessibility(prompt: true) {
            alert("Passwords integration is ready.", info: "Type “\(config.passwordsKeyword) github” in Seek.")
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change the login item.", info: error.localizedDescription)
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func alert(_ title: String, info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}
