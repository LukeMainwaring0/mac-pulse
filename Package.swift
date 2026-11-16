// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "InternetSpeed",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InternetSpeed", targets: ["InternetSpeed"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.6"
        )
    ],
    targets: [
        .executableTarget(
            name: "InternetSpeed",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(name: "InternetSpeedTests", dependencies: ["InternetSpeed"])
    ]
)
