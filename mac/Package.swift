// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vino",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything vino does: bottles, Wine, shortcuts, icons, setup. Used by both the app and its `vino` command.
        .target(name: "VinoCore", path: "Sources/VinoCore"),
        // One binary: `Vino run setup.exe` acts as the command-line tool, a plain launch opens the app.
        .executableTarget(name: "Vino", dependencies: ["VinoCore"], path: "Sources/Vino"),
        .testTarget(name: "VinoCoreTests", dependencies: ["VinoCore"], path: "Tests/VinoCoreTests"),
    ]
)
