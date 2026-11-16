// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MG6250",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PixmaKit", targets: ["PixmaKit"]),
        .executable(name: "mg6250scan", targets: ["mg6250scan"]),
        .executable(name: "MG6250Scanner", targets: ["MG6250Scanner"]),
    ],
    targets: [
        // The driver: BJNP network transport + Canon PIXMA scan protocol.
        .target(name: "PixmaKit"),
        // Command-line front end.
        .executableTarget(name: "mg6250scan", dependencies: ["PixmaKit"]),
        // SwiftUI app.
        .executableTarget(name: "MG6250Scanner", dependencies: ["PixmaKit"]),
    ]
)
