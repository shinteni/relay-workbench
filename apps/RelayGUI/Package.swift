// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayGUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayGUI", targets: ["RelayGUI"]),
    ],
    targets: [
        .executableTarget(
            name: "RelayGUI",
            resources: [.copy("Resources/protocol-version.txt")]
        ),
        .testTarget(name: "RelayGUITests", dependencies: ["RelayGUI"]),
    ],
    swiftLanguageModes: [.v5]
)
