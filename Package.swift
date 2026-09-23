// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirliftBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AirliftBrowser"),
        .testTarget(name: "AirliftBrowserTests", dependencies: ["AirliftBrowser"])
    ]
)
