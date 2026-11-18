import AppKit

enum Action: CaseIterable {
    case open, openWith, reveal, quickLook, copyPath, copyFile, moveTo, copyTo, rename, trash,
         openInTerminal, getInfo, compress, airDrop, showPackageContents, addToBuffer

    var title: String {
        switch self {
        case .open: return "Open"
        case .openWith: return "Open With…"
        case .reveal: return "Reveal in Finder"
        case .quickLook: return "Quick Look"
        case .copyPath: return "Copy Path"
        case .copyFile: return "Copy File"
        case .moveTo: return "Move To…"
        case .copyTo: return "Copy To…"
        case .rename: return "Rename…"
        case .trash: return "Move to Trash"
        case .openInTerminal: return "Open in Terminal"
        case .getInfo: return "Get Info"
        case .compress: return "Compress"
        case .airDrop: return "AirDrop"
        case .showPackageContents: return "Show Package Contents"
        case .addToBuffer: return "Add to Buffer"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .openWith: return "square.grid.2x2"
        case .reveal: return "folder"
        case .quickLook: return "eye"
        case .copyPath: return "link"
        case .copyFile: return "doc.on.doc"
        case .moveTo: return "folder.badge.plus"
        case .copyTo: return "plus.square.on.square"
        case .rename: return "pencil"
        case .trash: return "trash"
        case .openInTerminal: return "terminal"
        case .getInfo: return "info.circle"
        case .compress: return "archivebox"
        case .airDrop: return "airplayaudio"
        case .showPackageContents: return "shippingbox"
        case .addToBuffer: return "tray.and.arrow.down"
        }
    }

    /// Whether the action makes sense for these targets.
    static func available(for targets: [Item], buffered: Bool) -> [Action] {
        let single = targets.count == 1
        return allCases.filter { a in
            switch a {
            case .quickLook, .rename, .getInfo: return single
            case .showPackageContents: return single && (targets[0].kind == .app || PathFilter.isPackage(targets[0].path))
            case .addToBuffer: return !buffered
            default: return !targets.isEmpty
            }
        }
    }
}

enum FileOps {
    /// Moves or copies items into a folder, renaming ("name 2.ext") instead of overwriting.
    static func transfer(_ items: [Item], to folder: String, move: Bool) -> String? {
        var failures: [String] = []
        for item in items {
            let dest = uniqueDestination(for: item.url.lastPathComponent, in: URL(fileURLWithPath: folder))
            do {
                if move { try FileManager.default.moveItem(at: item.url, to: dest) }
                else { try FileManager.default.copyItem(at: item.url, to: dest) }
            } catch { failures.append(item.name) }
        }
        return failures.isEmpty ? nil : "Couldn't \(move ? "move" : "copy") " + failures.joined(separator: ", ")
    }

    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        var dest = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    static func rename(_ item: Item, to newName: String) -> String? {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("/") else { return "Invalid name" }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: dest.path) { return "“\(clean)” already exists" }
        do { try FileManager.default.moveItem(at: item.url, to: dest) } catch { return error.localizedDescription }
        return nil
    }

    static func openInTerminal(_ items: [Item]) {
        let folders = items.map { $0.kind == .folder ? $0.url : $0.url.deletingLastPathComponent() }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func getInfo(_ item: Item) {
        let path = item.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\"\nactivate\nopen information window of (POSIX file \"\(path)\" as alias)\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// Zips next to the originals, then reveals the archive.
    static func compress(_ items: [Item]) {
        guard let first = items.first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let parent = first.url.deletingLastPathComponent()
            let p = Process()
            let dest: URL
            if items.count == 1 {
                dest = uniqueDestination(for: first.url.lastPathComponent + ".zip", in: parent)
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path]
            } else {
                dest = uniqueDestination(for: "Archive.zip", in: parent)
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = parent
                let sameParent = items.allSatisfy { $0.url.deletingLastPathComponent() == parent }
                p.arguments = ["-r", "-q", "-y"] + (sameParent ? [] : ["-j"]) + [dest.path]
                    + items.map { sameParent ? $0.url.lastPathComponent : $0.path }
            }
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        }
    }

    static func airDrop(_ items: [Item]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map { $0.url as NSURL })
    }

    static func copyFiles(_ items: [Item]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }
}
