// swift-tools-version:6.0
import PackageDescription

// Swift 5 para no pelear con la concurrencia estricta en el POC
let package = Package(
    name: "rec",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "rec", path: "Sources/rec")],
    swiftLanguageModes: [.v5]
)
