// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BirdMenu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BirdMenu", targets: ["BirdMenu"])
    ],
    targets: [
        .executableTarget(
            name: "BirdMenu",
            path: "Sources/BirdMenu"
        ),
        .testTarget(
            name: "BirdMenuTests",
            dependencies: ["BirdMenu"],
            path: "Tests/BirdMenuTests"
        )
    ]
)
