// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NitpickKit",
    platforms: [.macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "ColorScience", targets: ["ColorScience"]),
        .library(name: "PatternLink", targets: ["PatternLink"]),
        .library(name: "LGControl", targets: ["LGControl"]),
        .library(name: "Calibration", targets: ["Calibration"]),
        .library(name: "MeterKit", targets: ["MeterKit"]),
    ],
    targets: [
        // Pure colour science: tristimulus types, transfer functions, colour spaces, ΔE, LUT maths, CGATS parsing.
        .target(name: "ColorScience"),
        // Pattern specification + Mac↔Apple TV wire protocol, framing, TLS-PSK transport, Bonjour.
        .target(name: "PatternLink", dependencies: ["ColorScience"]),
        // LG webOS SSAP client, discovery, settings, externalpq calibration API, fake TV server for tests.
        .target(name: "LGControl", dependencies: ["ColorScience"]),
        // Device protocols, simulated devices, optimizers, workflows, sessions, persistence, export.
        .target(name: "Calibration", dependencies: ["ColorScience", "PatternLink", "LGControl"]),
        // Calibrite Display Plus HL / i1d3 HID driver (macOS only; sources are #if os(macOS)).
        .target(name: "MeterKit", dependencies: ["ColorScience", "Calibration"]),

        .testTarget(name: "ColorScienceTests", dependencies: ["ColorScience"]),
        .testTarget(name: "PatternLinkTests", dependencies: ["PatternLink"]),
        .testTarget(name: "LGControlTests", dependencies: ["LGControl"]),
        .testTarget(name: "CalibrationTests", dependencies: ["Calibration"]),
        .testTarget(name: "MeterKitTests", dependencies: ["MeterKit"]),
    ],
    swiftLanguageModes: [.v6]
)
