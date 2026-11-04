// swift-tools-version: 6.4

// Module und Abhängigkeitsrichtung:
// UI-Module -> YuvomiCore <- YuvomiAPI. Der Kern kennt weder Generator noch Runtime;
// YuvomiAPI setzt seine Protokolle mit dem generierten Client um, die App verbindet beides.
// Die generierten Typen verlassen YuvomiAPI nicht.

import PackageDescription

let package = Package(
    name: "Yuvomi",
    defaultLocalization: "en",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "YuvomiCore", targets: ["YuvomiCore"]),
        .library(name: "YuvomiAPI", targets: ["YuvomiAPI"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "LoginFeature", targets: ["LoginFeature"]),
        .library(name: "TasksFeature", targets: ["TasksFeature"]),
        .library(name: "RemindersFeature", targets: ["RemindersFeature"]),
        .library(name: "YuvomiFixtures", targets: ["YuvomiFixtures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .target(name: "YuvomiCore"),
        .target(
            name: "YuvomiAPI",
            dependencies: [
                "YuvomiCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            exclude: ["openapi-generator-config.yaml"]
        ),
        .target(name: "DesignSystem"),
        // YuvomiAPI und YuvomiFixtures nur für die Vorschauen: Sie zeigen echte
        // v2.84.0-Antworten durch den echten Decoder. Die Screens selbst kennen nur den Kern.
        .target(
            name: "LoginFeature",
            dependencies: ["YuvomiCore", "DesignSystem", "YuvomiAPI", "YuvomiFixtures"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "TasksFeature",
            dependencies: ["YuvomiCore", "DesignSystem", "YuvomiAPI", "YuvomiFixtures"],
            resources: [.process("Localizable.xcstrings")]
        ),
        // Mitteilungen auf dem Gerät, Erlaubnis und Einstellungen. Kennt UserNotifications,
        // der Kern nicht.
        .target(
            name: "RemindersFeature",
            dependencies: ["YuvomiCore", "DesignSystem"],
            resources: [.process("Localizable.xcstrings")]
        ),
        // Die Antworten aus Fixtures/demo liegen außerhalb von Sources/, weil das
        // Abzugsskript sie dort ablegt. SPM bindet Ressourcen nur innerhalb des
        // Target-Ordners ein, deshalb zeigt das Target direkt auf Fixtures/.
        // `derived` sind Testvarianten, von Hand aus `demo` abgeleitet (siehe Fixtures/README.md).
        .target(
            name: "YuvomiFixtures",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Fixtures",
            exclude: ["README.md", "check-fixtures.mjs", "dump-fixtures.mjs"],
            sources: ["Swift"],
            resources: [.copy("demo"), .copy("derived")]
        ),
        .testTarget(name: "YuvomiCoreTests", dependencies: ["YuvomiCore", "YuvomiFixtures"]),
        .testTarget(name: "YuvomiAPITests", dependencies: ["YuvomiAPI", "YuvomiFixtures"]),
        .testTarget(name: "LoginFeatureTests", dependencies: ["LoginFeature", "YuvomiCore"]),
        .testTarget(name: "TasksFeatureTests", dependencies: ["TasksFeature", "YuvomiCore"]),
        .testTarget(name: "RemindersFeatureTests", dependencies: ["RemindersFeature", "YuvomiCore"]),
    ],
    swiftLanguageModes: [.v6]
)
