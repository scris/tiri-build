// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tiri",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TiriCore", targets: ["TiriCore"]),
        .executable(name: "TiriApp", targets: ["TiriApp"]),
        .executable(name: "tiri", targets: ["tiri"]),
        .executable(name: "tiri-session", targets: ["tiri-session"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "TiriCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .executableTarget(
            name: "TiriApp",
            dependencies: ["TiriCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "tiri", dependencies: ["TiriCore"]),
        .executableTarget(name: "tiri-session"),
        .testTarget(name: "TiriCoreTests", dependencies: ["TiriCore"]),
    ]
)
