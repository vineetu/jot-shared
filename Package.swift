// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JotTextPipeline",
    platforms: [
        // Floors sit intentionally below both consumers (iOS app: 26,
        // macOS app: 15) so the package never gates them. The pipeline is
        // Foundation-only string logic — nothing here needs a higher floor.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JotTextPipeline", targets: ["JotTextPipeline"]),
        .library(name: "JotVocabCore", targets: ["JotVocabCore"]),
    ],
    targets: [
        .target(
            name: "JotTextPipeline"
        ),
        .testTarget(
            name: "JotTextPipelineTests",
            dependencies: ["JotTextPipeline"],
            resources: [
                // Golden-fixture JSON is the cross-platform conformance
                // contract. A future non-Apple port must pass the same files.
                .copy("Fixtures"),
            ]
        ),
        // Vocabulary-correction core (Phase B). Foundation-only, no FluidAudio /
        // CoreML / UI / App-Group concept — the same platform floors as the text
        // pipeline. Bundles the per-language common-word lists as resources so its
        // default CommonWordsProvider can serve them via Bundle.module.
        .target(
            name: "JotVocabCore",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "JotVocabCoreTests",
            dependencies: ["JotVocabCore"],
            resources: [
                // Golden-fixture JSON — the cross-platform conformance contract
                // for the vocabulary correction core (same role as
                // JotTextPipelineTests/Fixtures).
                .copy("Fixtures"),
            ]
        ),
    ]
)
