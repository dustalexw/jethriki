// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YTDLPStudio",
    platforms: [.macOS(.v13)],
    // The app ships as "Jethriki"; the source target keeps its original name.
    products: [.executable(name: "Jethriki", targets: ["YTDLPStudio"])],
    targets: [
        .executableTarget(
            name: "YTDLPStudio",
            path: "Sources/YTDLPStudio"
        ),
        .testTarget(name: "YTDLPStudioTests", dependencies: ["YTDLPStudio"])
    ]
)
