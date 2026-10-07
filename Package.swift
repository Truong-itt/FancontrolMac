// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    targets: [
        // SMC access and the helper protocol, shared by all three programs.
        .target(name: "SMCKit"),
        // Root helper (LaunchDaemon); the only process that writes to the SMC.
        .executableTarget(name: "fancontrold", dependencies: ["SMCKit"]),
        // Command-line tool.
        .executableTarget(name: "fanctl", dependencies: ["SMCKit"]),
        // GUI app.
        .executableTarget(name: "FanControl", dependencies: ["SMCKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
