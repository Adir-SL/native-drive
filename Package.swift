// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NativeDrive",
    products: [
        .library(name: "NativeDriveCore", type: .static, targets: ["NativeDriveCore"])
    ],
    targets: [
        .target(name: "NativeDriveCore"),
        .testTarget(
            name: "NativeDriveCoreTests",
            dependencies: ["NativeDriveCore"]
        )
    ]
)
