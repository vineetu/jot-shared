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
    ]
)
