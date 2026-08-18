// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpossiBLE-Mock",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/mickeyl/SimBridgeKit.git", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "ImpossiBLEPassthroughCore",
            path: "PassthroughCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .executableTarget(
            name: "ImpossiBLE-Mock",
            dependencies: [
                "ImpossiBLEPassthroughCore",
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: ".",
            exclude: [
                "PassthroughCore",
                "Resources/Info.plist",
                "Resources/entitlements.plist",
                "Resources/bluetooth.svg.png"
            ],
            sources: [
                "MockApp.swift",
                "Models/AppVersion.swift",
                "Models/MockStore.swift",
                "Models/MockDevice.swift",
                "StatusBarController.swift",
                "Server/MockServer.swift",
                "Server/CaptureSession.swift",
                "Server/PassthroughActivity.swift",
                "Views/CaptureSheet.swift",
                "Views/DescriptorEditorView.swift",
                "Views/CharacteristicEditorView.swift",
                "Views/DeviceEditorView.swift",
                "Views/ServiceEditorView.swift",
                "Views/MockMenuContent.swift",
                "Views/EditorLayout.swift",
                "Views/FontAwesome.swift"
            ],
            resources: [
                .copy("Resources/fa-brands-400.ttf")
            ]
        )
    ]
)
