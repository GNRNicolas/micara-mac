// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Micara",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "LiveKitWebRTC", path: "Vendor/LiveKitWebRTC.xcframework"),
        .target(name: "MicaraCore"),
        .executableTarget(
            name: "Micara",
            dependencies: ["MicaraCore", "LiveKitWebRTC"]
        ),
        .testTarget(name: "MicaraCoreTests", dependencies: ["MicaraCore"]),
    ]
)
