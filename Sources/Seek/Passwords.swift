import AppKit
import ApplicationServices

/// Opens Apple's Passwords app and types the query into its search field (needs Accessibility permission).
enum PasswordsApp {
    static let url = URL(fileURLWithPath: "/System/Applications/Passwords.app")

    static func open(searching query: String) {
        if !query.isEmpty && !ensureAccessibility(prompt: false) {
            // The system prompt only appears once per app identity, so repeating it is useless.
            // Say what's wrong and open the list where Seek can be switched on.
            Toast.shared.show("Seek needs Accessibility access to search Passwords")
            SystemSetting.all.first { $0.anchor == "Privacy_Accessibility" }?.open()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let app, !query.isEmpty else { return }
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async { typeIntoSearch(pid: pid, text: query) }
        }
    }

    static func ensureAccessibility(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Waits (up to 60 s, so there's time to unlock with Touch ID) for the search field, then types into it.
    private static func typeIntoSearch(pid: pid_t, text: String) {
        guard ensureAccessibility(prompt: false) else { return }
        let app = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let field = findSearchField(in: app) {
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                Thread.sleep(forTimeInterval: 0.15)
                // Select whatever is there, then type, so the app's own search logic runs.
                postKey(pid: pid, keyCode: 0, flags: .maskCommand) // ⌘A
                postText(pid: pid, text)
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private static func findSearchField(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 4000 {
            let el = queue.removeFirst()
            visited += 1
            if string(el, kAXRoleAttribute) == kAXTextFieldRole as String,
               string(el, kAXSubroleAttribute) == kAXSearchFieldSubrole as String {
                return el
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func postKey(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }

    private static func postText(pid: pid_t, _ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text.utf16 {
            var c = ch
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.postToPid(pid)
            }
            usleep(4000)
        }
    }
}

/// A saved login as reported by apw. Passwords are never kept here; they are fetched at copy time.
struct Login: Hashable {
    let username: String
    let domain: String
}

/// Thin wrapper over the open-source `apw` CLI (github.com/bendews/apw), which talks to
/// iCloud Passwords through the same helper the browser extension uses.
enum APW {
    enum Failure: Error {
        case notInstalled, needsAuth, notRunning, failed(String)
    }

    static func executable(_ configured: String) -> String? {
        let candidates = [configured, "/opt/homebrew/bin/apw", "/usr/local/bin/apw"].filter { !$0.isEmpty }
        return candidates.first { FileManager.default.isExecutableFile(atPath: ($0 as NSString).expandingTildeInPath) }
            .map { ($0 as NSString).expandingTildeInPath }
    }

    /// "github" → "github.com"; anything with a dot is used as typed.
    static func domain(for query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.contains(".") ? q : q + ".com"
    }

    static func listLogins(_ exe: String, domain: String) -> Result<[Login], Failure> {
        switch run(exe, ["pw", "list", domain]) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            var logins: [Login] = []
            for entry in entries(in: out) {
                guard let user = field(entry, ["username", "user", "usr", "login", "account", "email"]) else { continue }
                let site = field(entry, ["domain", "site", "sites", "url", "website", "host"]) ?? domain
                logins.append(Login(username: user, domain: site))
            }
            var seen = Set<Login>()
            return .success(logins.filter { seen.insert($0).inserted })
        }
    }

    static func password(_ exe: String, login: Login, queryDomain: String) -> Result<String, Failure> {
        for d in Set([queryDomain, login.domain]) {
            guard case .success(let out) = run(exe, ["pw", "list", d]) else { continue }
            for entry in entries(in: out)
            where field(entry, ["username", "user", "usr", "login", "account", "email"]) == login.username {
                if let pw = field(entry, ["password", "pwd", "pass", "secret"]) { return .success(pw) }
            }
        }
        return .failure(.failed("No password returned for \(login.username)"))
    }

    static func otp(_ exe: String, domain: String) -> Result<String, Failure> {
        switch run(exe, ["otp", "get", domain]) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            for entry in entries(in: out) {
                if let code = field(entry, ["code", "otp", "totp", "token"]) { return .success(code) }
            }
            let text = String(decoding: out, as: UTF8.self)
            if let r = text.range(of: #"\b\d{6,8}\b"#, options: .regularExpression) { return .success(String(text[r])) }
            return .failure(.failed("No one-time code for \(domain)"))
        }
    }

    // MARK: Plumbing

    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 10) -> Result<Data, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.notInstalled) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        killer.cancel()
        // apw answers {"error": "...", "status": N, "results": [...]} and exits 0 even on errors.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = (obj["status"] as? NSNumber)?.intValue, status != 0 {
            switch status {
            case 3: return .success(data)                // no results
            case 9: return .failure(.needsAuth)          // not running or not paired ("unpaired")
            default:
                let msg = (obj["error"] as? String) ?? "apw error \(status)"
                return .failure(.failed(msg))
            }
        }
        if p.terminationStatus == 0 && !data.isEmpty { return .success(data) }
        let msg = (errText + " " + String(decoding: data, as: UTF8.self)).lowercased()
        if msg.contains("auth") || msg.contains("pin") || msg.contains("session") || msg.contains("pair") {
            return .failure(.needsAuth)
        }
        if msg.contains("daemon") || msg.contains("connect") || msg.contains("refused") || msg.contains("not running") {
            return .failure(.notRunning)
        }
        if p.terminationStatus == 0 { return .success(data) }
        return .failure(.failed(errText.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// apw's JSON layout isn't documented, so walk it and collect every object that looks like an entry.
    private static func entries(in data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var found: [[String: Any]] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                found.append(d)
                d.values.forEach(walk)
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(json)
        return found
    }

    private static func field(_ d: [String: Any], _ names: [String]) -> String? {
        for (k, v) in d where names.contains(k.lowercased()) {
            if let s = v as? String, !s.isEmpty { return s }
            if let a = v as? [String], let s = a.first { return s }
            if let n = v as? NSNumber { return n.stringValue }
        }
        return nil
    }

    /// Opens Terminal and runs an apw command that needs your input (e.g. the PIN for `apw auth`).
    static func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

enum SecureClipboard {
    /// Copies a secret, marked so clipboard managers skip it, and clears it after 45 s if unchanged.
    static func copy(_ secret: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.declareTypes([.string, concealed, transient], owner: nil)
        pb.setString(secret, forType: .string)
        pb.setString("", forType: concealed)
        pb.setString("", forType: transient)
        let stamp = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if NSPasteboard.general.changeCount == stamp { NSPasteboard.general.clearContents() }
        }
    }

    static func copyPlain(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
