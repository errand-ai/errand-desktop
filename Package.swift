// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ErrandDesktop",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "ErrandDesktop", targets: ["ErrandDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", from: "0.26.0"),
    ],
    targets: [
        .executableTarget(
            name: "ErrandDesktop",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
            ],
            path: "Sources/ErrandDesktop",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "ErrandDesktopTests",
            dependencies: ["ErrandDesktop"],
            path: "Tests/ErrandDesktopTests"
        ),
    ]
)
