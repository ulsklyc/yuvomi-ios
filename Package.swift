// swift-tools-version: 6.4

// Module und Abhängigkeitsrichtung: docs/plans/phase-1-slice-1.md, Abschnitt "Projektaufbau".
// UI-Module -> YuvomiCore -> YuvomiAPI. Die generierten Typen verlassen YuvomiAPI nicht.

import PackageDescription

let package = Package(
    name: "Yuvomi",
    defaultLocalization: "en",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "YuvomiCore", targets: ["YuvomiCore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "LoginFeature", targets: ["LoginFeature"]),
        .library(name: "TasksFeature", targets: ["TasksFeature"]),
        .library(name: "YuvomiFixtures", targets: ["YuvomiFixtures"]),
    ],
    targets: [
        .target(name: "YuvomiAPI"),
        .target(name: "YuvomiCore", dependencies: ["YuvomiAPI"]),
        .target(name: "DesignSystem"),
        .target(name: "LoginFeature", dependencies: ["YuvomiCore", "DesignSystem"]),
        .target(name: "TasksFeature", dependencies: ["YuvomiCore", "DesignSystem"]),
        // Die Antworten aus Fixtures/demo liegen außerhalb von Sources/, weil das
        // Abzugsskript sie dort ablegt. SPM bindet Ressourcen nur innerhalb des
        // Target-Ordners ein, deshalb zeigt das Target direkt auf Fixtures/.
        .target(
            name: "YuvomiFixtures",
            dependencies: ["YuvomiAPI"],
            path: "Fixtures",
            exclude: ["README.md", "check-fixtures.mjs", "dump-fixtures.mjs"],
            sources: ["Swift"],
            resources: [.copy("demo")]
        ),
        .testTarget(name: "YuvomiCoreTests", dependencies: ["YuvomiCore", "YuvomiFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
