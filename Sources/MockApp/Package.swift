// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpossiBLE-Mock",
    platforms: [.macOS("15.0")],
    products: [
        // The host-side provider as a library, so the Simsalabim suite app can
        // embed it alongside other providers. The standalone menu bar app is a
        // thin wrapper around the same target.
        .library(name: "ImpossiBLEProviderKit", targets: ["ImpossiBLEProviderKit"]),
        .executable(name: "ImpossiBLE-Mock", targets: ["ImpossiBLE-Mock"]),
    ],
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
        .target(
            name: "ImpossiBLEProviderKit",
            dependencies: [
                "ImpossiBLEPassthroughCore",
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: "ProviderKit",
            resources: [
                .copy("Resources/fa-brands-400.ttf")
            ]
        ),
        .executableTarget(
            name: "ImpossiBLE-Mock",
            dependencies: [
                "ImpossiBLEProviderKit",
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: "App"
        )
    ]
)
