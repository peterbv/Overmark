// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Presentify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Presentify", targets: ["PresentifyApp"]),
        .library(name: "PresentifyCore", targets: ["PresentifyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        // MARK: - Core (no UI, no side effects — fully testable)
        .target(name: "PresentifyCore"),

        // MARK: - Platform services
        .target(name: "PresentifyCapture", dependencies: ["PresentifyCore"]),
        .target(
            name: "PresentifyHotkeys",
            dependencies: [
                "PresentifyCore",
                .product(name: "HotKey", package: "HotKey"),
            ]
        ),
        .target(
            name: "PresentifyCursor",
            dependencies: ["PresentifyCore", "PresentifyCapture"]
        ),
        .target(name: "PresentifyOverlay", dependencies: ["PresentifyCore", "PresentifyCapture"]),

        // MARK: - App
        .executableTarget(
            name: "PresentifyApp",
            dependencies: [
                "PresentifyCore",
                "PresentifyCapture",
                "PresentifyOverlay",
                "PresentifyHotkeys",
                "PresentifyCursor",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(name: "PresentifyCoreTests", dependencies: ["PresentifyCore"]),
        .testTarget(
            name: "PresentifyCaptureTests",
            dependencies: ["PresentifyCapture"]
        ),
        .testTarget(
            name: "PresentifyHotkeysTests",
            dependencies: ["PresentifyHotkeys"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
