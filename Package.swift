// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpossiBLE",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "ImpossiBLE",
            targets: ["ImpossiBLE"]
        ),
    ],
    targets: [
        .target(
            name: "ImpossiBLE",
            path: "Sources/ImpossiBLE",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
            ]
        ),
    ]
)
