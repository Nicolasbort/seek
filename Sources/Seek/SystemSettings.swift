import AppKit

/// A System Settings pane (or a section inside one) that Seek can open directly.
struct SystemSetting {
    let title: String
    /// Pane id for `x-apple.systempreferences:` (the settings extension's bundle id).
    let pane: String
    /// Optional section inside the pane, e.g. "Privacy_Accessibility".
    var anchor: String? = nil
    /// Other names it answers to.
    var keywords: [String] = []

    var url: URL {
        URL(string: "x-apple.systempreferences:\(pane)" + (anchor.map { "?" + $0 } ?? ""))!
    }

    var subtitle: String { anchor == nil ? "System Settings" : "System Settings · Privacy & Security" }

    func open() { NSWorkspace.shared.open(url) }

    static let appURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// The pane's own icon (Keyboard, Displays, …), falling back to the System Settings icon.
    var iconPath: String { SystemSetting.bundlePaths[pane] ?? SystemSetting.appURL.path }

    /// Settings extension bundle id → .appex path, found once by reading the extensions' Info.plists.
    private static let bundlePaths: [String: String] = {
        var map: [String: String] = [:]
        let dirs = ["/System/Library/ExtensionKit/Extensions",
                    "/System/Applications/System Settings.app/Contents/PlugIns",
                    "/System/Library/CoreServices/Spotlight.app/Contents/Extensions"]
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".appex") {
                let path = dir + "/" + name
                if let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                   let id = info["CFBundleIdentifier"] as? String {
                    map[id] = path
                }
            }
        }
        return map
    }()

    // MARK: Catalogue
    // Ids were checked against /System/Library/ExtensionKit/Extensions on macOS 26.

    private static let privacy = "com.apple.settings.PrivacySecurity.extension"

    static let all: [SystemSetting] = [
        .init(title: "Wi-Fi", pane: "com.apple.wifi-settings-extension", keywords: ["wifi", "wireless", "internet"]),
        .init(title: "Bluetooth", pane: "com.apple.BluetoothSettings", keywords: ["airpods", "pairing"]),
        .init(title: "Network", pane: "com.apple.Network-Settings.extension", keywords: ["ethernet", "dns", "proxy", "ip address", "firewall"]),
        .init(title: "VPN", pane: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"),
        .init(title: "Battery", pane: "com.apple.Battery-Settings.extension", keywords: ["energy", "power", "low power mode", "energy saver"]),
        .init(title: "General", pane: "com.apple.systempreferences.GeneralSettings"),
        .init(title: "About This Mac", pane: "com.apple.SystemProfiler.AboutExtension", keywords: ["about", "serial number", "macos version"]),
        .init(title: "Software Update", pane: "com.apple.Software-Update-Settings.extension", keywords: ["update", "upgrade macos"]),
        .init(title: "Storage", pane: "com.apple.settings.Storage", keywords: ["disk space", "free space"]),
        .init(title: "AirDrop & Handoff", pane: "com.apple.AirDrop-Handoff-Settings.extension", keywords: ["airdrop", "handoff", "airplay receiver"]),
        .init(title: "Login Items & Extensions", pane: "com.apple.LoginItems-Settings.extension", keywords: ["login items", "startup items", "open at login", "extensions"]),
        .init(title: "Language & Region", pane: "com.apple.Localization-Settings.extension", keywords: ["language", "region", "locale", "date format"]),
        .init(title: "Date & Time", pane: "com.apple.Date-Time-Settings.extension", keywords: ["date", "time", "clock", "time zone"]),
        .init(title: "Sharing", pane: "com.apple.Sharing-Settings.extension", keywords: ["file sharing", "screen sharing", "remote login", "ssh", "computer name"]),
        .init(title: "Time Machine", pane: "com.apple.Time-Machine-Settings.extension", keywords: ["backup"]),
        .init(title: "Transfer or Reset", pane: "com.apple.Transfer-Reset-Settings.extension", keywords: ["erase", "factory reset"]),
        .init(title: "Startup Disk", pane: "com.apple.Startup-Disk-Settings.extension", keywords: ["boot"]),
        .init(title: "Device Management", pane: "com.apple.Profiles-Settings.extension", keywords: ["profiles", "mdm"]),
        .init(title: "Accessibility", pane: "com.apple.Accessibility-Settings.extension", keywords: ["voiceover", "zoom", "reduce motion", "reduce transparency"]),
        .init(title: "Appearance", pane: "com.apple.Appearance-Settings.extension", keywords: ["dark mode", "light mode", "accent color", "theme"]),
        .init(title: "Apple Intelligence & Siri", pane: "com.apple.Siri-Settings.extension", keywords: ["siri", "apple intelligence"]),
        .init(title: "Control Center", pane: "com.apple.ControlCenter-Settings.extension", keywords: ["menu bar", "menubar"]),
        .init(title: "Desktop & Dock", pane: "com.apple.Desktop-Settings.extension", keywords: ["dock", "mission control", "hot corners", "stage manager", "windows"]),
        .init(title: "Displays", pane: "com.apple.Displays-Settings.extension", keywords: ["display", "monitor", "resolution", "night shift", "brightness", "screen"]),
        .init(title: "Spotlight", pane: "com.apple.Spotlight-Settings.extension"),
        .init(title: "Wallpaper", pane: "com.apple.Wallpaper-Settings.extension", keywords: ["background", "desktop picture", "screen saver"]),
        .init(title: "Notifications", pane: "com.apple.Notifications-Settings.extension", keywords: ["alerts", "banners"]),
        .init(title: "Sound", pane: "com.apple.Sound-Settings.extension", keywords: ["volume", "audio", "output", "input", "speakers", "alert sound"]),
        .init(title: "Focus", pane: "com.apple.Focus-Settings.extension", keywords: ["do not disturb", "dnd"]),
        .init(title: "Screen Time", pane: "com.apple.Screen-Time-Settings.extension"),
        .init(title: "Lock Screen", pane: "com.apple.Lock-Screen-Settings.extension", keywords: ["screen saver timer", "require password"]),
        .init(title: "Privacy & Security", pane: privacy, keywords: ["privacy", "security", "gatekeeper", "filevault"]),
        .init(title: "Touch ID & Password", pane: "com.apple.Touch-ID-Settings.extension", keywords: ["touch id", "fingerprint", "password"]),
        .init(title: "Users & Groups", pane: "com.apple.Users-Groups-Settings.extension", keywords: ["users", "accounts", "guest"]),
        .init(title: "Internet Accounts", pane: "com.apple.Internet-Accounts-Settings.extension", keywords: ["mail accounts", "google account"]),
        .init(title: "Game Center", pane: "com.apple.Game-Center-Settings.extension"),
        .init(title: "Game Controllers", pane: "com.apple.Game-Controller-Settings.extension", keywords: ["gamepad", "controller"]),
        .init(title: "Wallet & Apple Pay", pane: "com.apple.WalletSettingsExtension", keywords: ["apple pay", "wallet"]),
        .init(title: "Keyboard", pane: "com.apple.Keyboard-Settings.extension", keywords: ["keyboard shortcuts", "input sources", "dictation", "key repeat", "text replacements"]),
        .init(title: "Mouse", pane: "com.apple.Mouse-Settings.extension", keywords: ["pointer", "scroll direction"]),
        .init(title: "Trackpad", pane: "com.apple.Trackpad-Settings.extension", keywords: ["gestures", "tap to click", "scroll direction"]),
        .init(title: "Printers & Scanners", pane: "com.apple.Print-Scan-Settings.extension", keywords: ["printer", "scanner", "print"]),
        .init(title: "Family", pane: "com.apple.Family-Settings.extension", keywords: ["family sharing"]),
        .init(title: "Apple Account", pane: "com.apple.systempreferences.AppleIDSettings", keywords: ["apple id", "icloud"]),

        // Privacy & Security sections
        .init(title: "Accessibility Permissions", pane: privacy, anchor: "Privacy_Accessibility", keywords: ["accessibility access"]),
        .init(title: "Full Disk Access", pane: privacy, anchor: "Privacy_AllFiles"),
        .init(title: "Files & Folders", pane: privacy, anchor: "Privacy_FilesAndFolders"),
        .init(title: "Screen & System Audio Recording", pane: privacy, anchor: "Privacy_ScreenCapture", keywords: ["screen recording", "screenshot permission"]),
        .init(title: "Input Monitoring", pane: privacy, anchor: "Privacy_ListenEvent"),
        .init(title: "Automation", pane: privacy, anchor: "Privacy_Automation", keywords: ["apple events"]),
        .init(title: "Camera", pane: privacy, anchor: "Privacy_Camera", keywords: ["webcam"]),
        .init(title: "Microphone", pane: privacy, anchor: "Privacy_Microphone", keywords: ["mic"]),
        .init(title: "Location Services", pane: privacy, anchor: "Privacy_LocationServices", keywords: ["location", "gps"]),
        .init(title: "Developer Tools", pane: privacy, anchor: "Privacy_DevTools"),
    ]

    /// Settings matching the query by prefix or word start (2+ characters), best first,
    /// with a score comparable to an app's in `Launcher.mergeSettings`.
    static func matching(_ text: String, limit: Int = 4) -> [(SystemSetting, Int32)] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let first = q.first, !"/~.".contains(first), !q.contains(":") else { return [] }
        let terms = q.split(separator: " ").map { foldKey(String($0)) }
        var hits: [(SystemSetting, Int32)] = []
        for s in all {
            let best = ([s.title] + s.keywords).map { Matcher.scoreAll(terms, key: foldKey($0)) }.max() ?? -1
            if best >= 800 { hits.append((s, best)) }
        }
        return Array(hits.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}

extension Row {
    static func systemSetting(_ s: SystemSetting) -> Row {
        Row(title: s.title, subtitle: s.subtitle, payload: .systemSetting(s))
    }
}
