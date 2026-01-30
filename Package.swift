// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacMCPControl",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "MacMCPControl",
            dependencies: [
                .product(name: "Swifter", package: "swifter")
            ],
            resources: [
                .copy("Resources/ngrok"),
                .process("Resources/AppIcon.icns"),
                .process("Resources/AppIcon.iconset"),
                .process("Resources/icon-app.svg"),
                .process("Resources/icon-menu.svg"),
                .process("Resources/MenuBarIcon.png")
            ]
        ),
    ]
)
