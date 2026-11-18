// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Seek",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Seek",
            path: "Sources/Seek",
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"])]
        )
    ]
)
