// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpossiBLE-Mock",
    platforms: [.macOS("15.0")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ImpossiBLE-Mock",
            dependencies: [],
            path: ".",
            exclude: [
                "Resources/Info.plist",
                "Resources/entitlements.plist",
                "Resources/bluetooth.svg.png"
            ],
            sources: [
                "MockApp.swift",
                "Models/MockStore.swift",
                "Models/MockProviderMode.swift",
                "Models/MockDevice.swift",
                "Server/MockServer.swift",
                "Server/ForwarderController.swift",
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
