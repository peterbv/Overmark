// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Overmark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Overmark", targets: ["OvermarkApp"]),
        .library(name: "OvermarkCore", targets: ["OvermarkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        // MARK: - Core (no UI, no side effects — fully testable)
        .target(name: "OvermarkCore"),

        // MARK: - Platform services
        .target(name: "OvermarkCapture", dependencies: ["OvermarkCore"]),
        .target(
            name: "OvermarkRecorder",
            dependencies: ["OvermarkCore", "OvermarkCapture"]
        ),
        .target(
            name: "OvermarkHotkeys",
            dependencies: [
                "OvermarkCore",
                .product(name: "HotKey", package: "HotKey"),
            ]
        ),
        .target(
            name: "OvermarkCursor",
            dependencies: ["OvermarkCore", "OvermarkCapture"]
        ),
        .target(name: "OvermarkOverlay", dependencies: ["OvermarkCore", "OvermarkCapture"]),

        // MARK: - App
        .executableTarget(
            name: "OvermarkApp",
            dependencies: [
                "OvermarkCore",
                "OvermarkCapture",
                "OvermarkOverlay",
                "OvermarkHotkeys",
                "OvermarkCursor",
                "OvermarkRecorder",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(name: "OvermarkCoreTests", dependencies: ["OvermarkCore"]),
        .testTarget(
            name: "OvermarkCaptureTests",
            dependencies: ["OvermarkCapture"]
        ),
        .testTarget(
            name: "OvermarkRecorderTests",
            dependencies: ["OvermarkRecorder"]
        ),
        .testTarget(
            name: "OvermarkHotkeysTests",
            dependencies: ["OvermarkHotkeys"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
