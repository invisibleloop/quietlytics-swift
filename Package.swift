// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Quietlytics",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [.library(name: "Quietlytics", targets: ["Quietlytics"])],
    targets: [
        .target(name: "Quietlytics", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "QuietlyticsTests", dependencies: ["Quietlytics"]),
    ]
)
