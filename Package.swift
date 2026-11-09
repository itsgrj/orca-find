// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OrcaFind",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device English speech model runtime (Parakeet via Core ML). The model itself is an optional
        // download from Settings; nothing is bundled.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .executableTarget(
            name: "OrcaFind",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
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
