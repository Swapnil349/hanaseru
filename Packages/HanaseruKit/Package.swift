// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral core of Hanaseru. Nothing in here imports UIKit, AVFoundation,
// Speech or SwiftData, so it builds and tests on macOS, Linux and Windows.
let package = Package(
    name: "HanaseruKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LearningCore", targets: ["LearningCore"]),
        .library(name: "ConversationCore", targets: ["ConversationCore"]),
        .library(name: "SessionCore", targets: ["SessionCore"]),
    ],
    targets: [
        .target(
            name: "LearningCore",
            resources: [.process("Content")]
        ),
        .target(
            name: "ConversationCore",
            dependencies: ["LearningCore"]
        ),
        .target(
            name: "SessionCore",
            dependencies: ["LearningCore", "ConversationCore"]
        ),
        .testTarget(name: "LearningCoreTests", dependencies: ["LearningCore"]),
        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ],
    swiftLanguageModes: [.v5]
)
