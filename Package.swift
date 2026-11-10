// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FastShot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FastShot", targets: ["FastShot"])],
    targets: [
        .executableTarget(name: "FastShot", path: "FastShot", exclude: ["Assets.xcassets"], resources: [.copy("Resources")], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "FastShotTests", dependencies: ["FastShot"], path: "Tests/FastShotTests")
    ]
)
