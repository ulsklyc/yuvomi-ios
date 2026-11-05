import YuvomiCore

/// Ein Stück der Beschreibung, so wie das Detail es zeigt: zusammenhängender Text oder ein
/// Punkt der Checkliste (Q11).
enum DescriptionBlock: Hashable {
    case text(String)
    case point(Checklist.Point)

    /// Zeilen ohne Kästchen bilden einen Block, Leerzeilen am Rand fallen weg, Leerzeilen
    /// mitten im Text bleiben. Ein Punkt der Checkliste trennt Text.
    static func blocks(of checklist: Checklist) -> [DescriptionBlock] {
        var blocks: [DescriptionBlock] = []
        var text: [String] = []
        func flush() {
            let trimmed = text.drop { $0.allSatisfy(\.isWhitespace) }.reversed().drop { $0.allSatisfy(\.isWhitespace) }.reversed()
            if !trimmed.isEmpty { blocks.append(.text(trimmed.joined(separator: "\n"))) }
            text = []
        }
        for line in checklist.lines {
            if let item = line.item {
                flush()
                blocks.append(.point(Checklist.Point(index: line.index, raw: line.raw, isChecked: item.isChecked, text: item.text)))
            } else {
                text.append(line.raw)
            }
        }
        flush()
        return blocks
    }
}
