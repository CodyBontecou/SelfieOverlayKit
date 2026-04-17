// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SelfieOverlayKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SelfieOverlayKit",
            targets: ["SelfieOverlayKit"]
        )
    ],
    targets: [
        .target(
            name: "SelfieOverlayKit",
            path: "Sources/SelfieOverlayKit"
        ),
        .testTarget(
            name: "SelfieOverlayKitTests",
            dependencies: ["SelfieOverlayKit"],
            path: "Tests/SelfieOverlayKitTests"
        )
    ]
)
