// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "UsageBar",
            path: "Sources/UsageBar",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
