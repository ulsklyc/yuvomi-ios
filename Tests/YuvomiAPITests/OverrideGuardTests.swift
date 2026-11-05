import Foundation
import Testing
@testable import YuvomiAPI

/// Seam 3 (Q15): Die handgeschriebenen Eingaben für Aufgaben kennen jedes Feld der Spec.
/// Kommt mit einem Spec-Update ein Feld dazu, scheitert dieser Test, statt dass der Override
/// still veraltet.
@Suite struct OverrideGuardTests {
    /// Felder, die der Override bewusst nicht kennt. Bisher keine.
    static let omitted: [String: Set<String>] = [:]

    static func properties(_ schema: String) throws -> Set<String> {
        let spec = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Spec/openapi.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: spec)) as? [String: Any]
        let schemas = (json?["components"] as? [String: Any])?["schemas"] as? [String: Any]
        let object = schemas?[schema] as? [String: Any]
        return Set((object?["properties"] as? [String: Any] ?? [:]).keys)
    }

    @Test(arguments: [
        ("TaskCreateInput", Set(TaskCreateInput.CodingKeys.allCases.map(\.rawValue))),
        ("TaskUpdateInput", Set(TaskUpdateInput.CodingKeys.allCases.map(\.rawValue))),
    ])
    func overrideMatchesTheSpec(schema: String, keys: Set<String>) throws {
        let spec = try Self.properties(schema)
        #expect(!spec.isEmpty, "\(schema) fehlt in Spec/openapi.json")
        #expect(spec.subtracting(keys).subtracting(Self.omitted[schema] ?? []) == [], "In der Spec, im Override nicht")
        #expect(keys.subtracting(spec) == [], "Im Override, in der Spec nicht")
    }
}
