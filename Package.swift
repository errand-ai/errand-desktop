// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ErrandDesktop",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ErrandDesktop", targets: ["ErrandDesktop"]),
    ],
    dependencies: [
        // Pinned to a tight range: the package declares its own `.macOS("15")` floor,
        // and a future minor bump could silently raise our minimum deployment target.
        .package(url: "https://github.com/apple/containerization.git", "0.26.0"..<"0.45.0"),
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
