import AppKit
import UniformTypeIdentifiers

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The panel background: Liquid Glass (NSGlassEffectView) on macOS 26, frosted vibrancy before that.
final class GlassContainer: NSView {
    let content = FlippedView()
    private var glass: NSView!
    private var applyRadius: (CGFloat) -> Void = { _ in }

    var cornerRadius: CGFloat = 28 {
        didSet {
            guard oldValue != cornerRadius else { return }
            applyRadius(cornerRadius)
            layer?.cornerRadius = cornerRadius
            window?.invalidateShadow()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Clip everything (glass included) to the rounded shape so the window's
        // alpha, and therefore its shadow, follows the corners instead of a square.
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.contentView = content
            glass = g
            applyRadius = { g.cornerRadius = $0 }
        }
        #endif
        if glass == nil {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.maskImage = GlassContainer.mask(radius: cornerRadius)
            v.addSubview(content)
            glass = v
            applyRadius = { [weak v] r in v?.maskImage = GlassContainer.mask(radius: r) }
        }
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateShadow()
    }

    private static func mask(radius r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// Borderless panel that can take keyboard focus without activating Seek,
/// so the app you were in stays frontmost.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A result row in the list.
struct Row {
    enum Payload {
        case item(Item)
        case action(Action)
        case openWithApp(URL)
        case passwordsApp(String)
        case login(Login, String)   // login, domain as queried
        case terminal(String)       // run a command in Terminal
        case command(SeekCommand)   // Seek's own commands (Settings, Rebuild Index, Quit)
        case systemSetting(SystemSetting) // a System Settings pane
        case info
    }
    var title: String
    var subtitle: String
    var payload: Payload
    var symbol: String? = nil

    static func item(_ i: Item) -> Row { Row(title: i.name, subtitle: i.location, payload: .item(i)) }

    var item: Item? { if case .item(let i) = payload { return i }; return nil }
}

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for row: Row) -> NSImage? {
        switch row.payload {
        case .item(let i): return icon(for: i)
        case .openWithApp(let url): return cached("app:" + url.path) { NSWorkspace.shared.icon(forFile: url.path) }
        case .passwordsApp: return cached("app:" + PasswordsApp.url.path) { NSWorkspace.shared.icon(forFile: PasswordsApp.url.path) }
        case .systemSetting(let s): return cached("path:" + s.iconPath) { NSWorkspace.shared.icon(forFile: s.iconPath) }
        default:
            return symbol(row.symbol ?? "circle")
        }
    }

    static func icon(for item: Item) -> NSImage {
        switch item.kind {
        case .app, .folder:
            return cached("path:" + item.path) { NSWorkspace.shared.icon(forFile: item.path) }
        case .file:
            let ext = (item.path as NSString).pathExtension.lowercased()
            if PathFilter.isPackage(item.path) {
                return cached("path:" + item.path) { NSWorkspace.shared.icon(forFile: item.path) }
            }
            return cached("ext:" + ext) {
                NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            }
        }
    }

    static func symbol(_ name: String) -> NSImage? {
        cached("sym:" + name) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let img = cache.object(forKey: key as NSString) { return img }
        let img = make()
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}

/// Selection drawn as a soft accent-tinted rounded rect, in keeping with Liquid Glass.
final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

final class ResultCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [icon, title, subtitle, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        badge.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        for f in [title, subtitle] { f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: Row, badge text: String) {
        icon.image = Icons.image(for: row)
        title.stringValue = row.title
        subtitle.stringValue = row.subtitle
        subtitle.isHidden = row.subtitle.isEmpty
        badge.stringValue = text
    }
}

/// Small rounded label used for the mode chip ("Move To…", "Actions").
final class Chip: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; label.sizeToFit(); needsLayout = true }
    }

    /// Width the chip wants for its current text.
    var fittingWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 20 }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        }
    }
}
