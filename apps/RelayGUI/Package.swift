// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayGUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayGUI", targets: ["RelayGUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "RelayGUI",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/protocol-version.txt")]
        ),
        .testTarget(name: "RelayGUITests", dependencies: ["RelayGUI"]),
    ],
    swiftLanguageModes: [.v5]
)
