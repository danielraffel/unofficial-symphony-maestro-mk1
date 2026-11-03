// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maestro",
    platforms: [
        .macOS(.v15)  // macOS 26 (Tahoe) — will bump to v16 when SDK ships
    ],
    products: [
        .executable(name: "MaestroApp", targets: ["MaestroApp"]),
        .executable(name: "HardwareTest", targets: ["HardwareTest"]),
        .library(name: "MaestroCore", targets: ["MaestroCore"]),
        .library(name: "MaestroDevice", targets: ["MaestroDevice"]),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        // MARK: - App
        .executableTarget(
            name: "MaestroApp",
            dependencies: ["MaestroCore", "MaestroDevice", .product(name: "Sparkle", package: "Sparkle")],
            path: "MaestroApp",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIconRounded.icns"),
                .copy("Resources/Terms.html"),
                .copy("Resources/Privacy.html"),
                .copy("Resources/Acknowledgements.html"),
            ]
        ),

        // MARK: - Core domain model + business logic
        .target(
            name: "MaestroCore",
            path: "MaestroCore"
        ),

        // MARK: - Device communication abstraction
        .target(
            name: "MaestroDevice",
            dependencies: ["MaestroCore"],
            path: "MaestroDevice",
            linkerSettings: [
                .linkedFramework("IOUSBHost", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
            ]
        ),

        // MARK: - C shim for deprecated CoreAudio APIs
        .target(
            name: "LegacyCoreAudio",
            path: "LegacyCoreAudio",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
            ]
        ),

        // MARK: - Hardware Test CLI
        .executableTarget(
            name: "HardwareTest",
            dependencies: ["MaestroCore", "MaestroDevice", "LegacyCoreAudio"],
            path: "HardwareTest",
            linkerSettings: [
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "MaestroCoreTests",
            dependencies: ["MaestroCore"],
            path: "Tests/MaestroCoreTests"
        ),
        .testTarget(
            name: "MaestroDeviceTests",
            dependencies: ["MaestroDevice"],
            path: "Tests/MaestroDeviceTests"
        ),
    ]
)
