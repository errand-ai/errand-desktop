// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ErrandDesktop",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-containerization.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ErrandDesktop",
            dependencies: [
                .product(name: "Containerization", package: "swift-containerization"),
                .product(name: "ContainerizationOCI", package: "swift-containerization"),
            ],
            path: "Sources/ErrandDesktop"
        ),
        .testTarget(
            name: "ErrandDesktopTests",
            dependencies: ["ErrandDesktop"],
            path: "Tests/ErrandDesktopTests"
        ),
    ]
)
