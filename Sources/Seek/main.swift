import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--bench") {
    Bench.run(Array(args[(i + 1)...]))
    exit(0)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
