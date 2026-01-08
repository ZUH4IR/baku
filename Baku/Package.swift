// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Baku",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Baku", targets: ["Baku"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.0.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "8.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Baku",
            dependencies: [
                "Defaults",
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources/Baku",
            resources: [
                .copy("Resources/Icons")
            ]
        )
    ]
)
