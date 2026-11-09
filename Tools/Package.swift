// swift-tools-version: 6.4

// Werkzeuge für die Entwicklung, getrennt vom App-Paket, damit der Generator nie
// in einen App-Build gerät. Aufruf über scripts/generate-api.sh.

import PackageDescription

let package = Package(
    name: "YuvomiTools",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Version aus dem Spike vom 02.11.2026 (Server-Regel S5).
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4"),
    ],
    targets: []
)
