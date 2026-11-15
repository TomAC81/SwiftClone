// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftClone",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SwiftCloneCore", targets: ["SwiftCloneCore"]),
        .executable(name: "SwiftClone", targets: ["SwiftClone"]),
    ],
    targets: [
        .target(name: "SwiftCloneCore"),
        .executableTarget(
            name: "SwiftClone",
            dependencies: ["SwiftCloneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SwiftCloneCoreTests", dependencies: ["SwiftCloneCore"]),
    ]
)
