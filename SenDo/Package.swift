// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SenDo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SenDo", targets: ["SenDo"])
    ],
    dependencies: [
        // No external dependencies - using native frameworks only
    ],
    targets: [
        .executableTarget(
            name: "SenDo",
            dependencies: [],
            path: "Sources"
        )
    ]
)
