import AppKit

/// `--demo`: for README screenshots. Run with CFFIXED_USER_HOME pointing at a demo home folder so
/// Seek indexes fake files and keeps its own config. A full-screen gradient sits behind the panel,
/// so the glass shows the gradient instead of whatever is on screen. Geometry for the capture
/// script is written to $SEEK_DEMO_OUT (default /tmp/seek-demo.json).
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo")

    private static var backdrop: NSWindow?

    static func showBackdrop() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) // just under the panel
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = GradientView()
        w.orderFrontRegardless()
        backdrop = w
    }

    /// Writes the panel's rect (top-left origin, points) once results have had time to land.
    static func report(frame: @autoclosure @escaping () -> NSRect) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let f = frame()
            let screenH = (NSScreen.screens.first ?? NSScreen.main!).frame.height
            write(["x": f.minX, "y": screenH - f.maxY, "w": f.width, "h": f.height])
        }
    }

    static func report(windowNumber: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { write(["window": windowNumber]) }
    }

    private static func write(_ obj: [String: Any]) {
        let path = ProcessInfo.processInfo.environment["SEEK_DEMO_OUT"] ?? "/tmp/seek-demo.json"
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    private final class GradientView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // Same palette as the app icon, softened.
            let g = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.10, blue: 0.42, alpha: 1),
                                        NSColor(srgbRed: 0.27, green: 0.25, blue: 0.80, alpha: 1),
                                        NSColor(srgbRed: 0.20, green: 0.70, blue: 0.85, alpha: 1)],
                                atLocations: [0, 0.5, 1], colorSpace: .sRGB)
            g?.draw(in: bounds, angle: 35)
            // A couple of soft blobs so the glass has something to refract.
            for (x, y, r, a) in [(0.30, 0.65, 0.28, 0.35), (0.72, 0.35, 0.22, 0.30)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                let c = NSPoint(x: bounds.width * x, y: bounds.height * y)
                let radius = bounds.width * r
                NSGradient(starting: NSColor.white.withAlphaComponent(a), ending: NSColor.white.withAlphaComponent(0))?
                    .draw(fromCenter: c, radius: 0, toCenter: c, radius: radius, options: [])
            }
        }
    }
}
