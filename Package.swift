// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OrcaFind",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OrcaFind",
            path: "Sources/OrcaFind",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // SwiftUI's VideoPlayer lives in the _AVKit_SwiftUI overlay, whose classes subclass AVKit's.
                // SwiftPM only autolinks the overlay, so without this AVKit isn't loaded and the first
                // VideoPlayer (Inspector preview of a video) aborts in getSuperclassMetadata.
                .linkedFramework("AVKit"),
                // Apple Intelligence's on-device model only exists on macOS 26+. Weak-link it so the
                // app still launches on macOS 14/15 (SentenceUnderstanding checks availability).
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        )
    ]
)
