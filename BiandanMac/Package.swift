// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BiandanMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BiandanMac", targets: ["BiandanMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // 自动更新：appcast 放在自己的服务器上，更新包用 EdDSA 签名校验。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "BiandanMac",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BiandanMac",
            // 打包后 Sparkle.framework 放在 Contents/Frameworks。
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BiandanMacTests",
            dependencies: ["BiandanMac"],
            path: "Tests/BiandanMacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
