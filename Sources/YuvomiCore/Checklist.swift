/// Die Beschreibung einer Aufgabe, zerlegt in Zeilen, mit den Punkten der Checkliste.
///
/// Dieselbe Regel wie `public/utils/markdown-checklist.js` im Server (`v2.84.0`): Der Server
/// zählt die Zeilen und entscheidet, welche sich ankreuzen lässt. Weicht die App ab, zeigt sie
/// ein Kästchen, das der Server nicht kennt, oder kreuzt eine andere Zeile an.
///
/// - Zeilen trennen `\r\n`, `\n` und `\r` (`splitKeepingLineEndings`), gezählt ab 0.
/// - Ein Punkt ist `^( {0,3}[-*+]\s+\[)([ xX])(\]\s+.*)$` (`CHECKLIST_RE`).
///
/// Gerechnet wird auf Unicode-Skalaren, nicht auf `Character`: Für Swift ist `\r\n` ein einziges
/// Zeichen, und `\s` soll genau die Leerzeichen von JavaScript treffen.
public struct Checklist: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var isChecked: Bool
        /// Der Text hinter dem Kästchen, ohne die Leerzeichen davor.
        public var text: String
    }

    /// Ein Punkt der Checkliste mit allem, was das Ankreuzen braucht.
    public struct Point: Hashable, Sendable, Identifiable {
        /// Die Nummer, die der Server als `line` erwartet.
        public var index: Int
        /// Die Zeile ohne Trenner, für `expect`.
        public var raw: String
        public var isChecked: Bool
        public var text: String
        public var id: Int { index }
    }

    public struct Line: Hashable, Sendable {
        /// Die Nummer, die der Server als `line` erwartet.
        public var index: Int
        /// Die Zeile ohne Trenner, so wie der Server sie als `expect` vergleicht.
        public var raw: String
        /// `nil` für eine Zeile, die kein Punkt der Checkliste ist.
        public var item: Item?
    }

    public let lines: [Line]
    /// Nur die Punkte der Checkliste, in der Reihenfolge der Zeilen.
    public let items: [Point]

    /// - Parameter description: `nil` ergibt keine Zeilen. Ein leerer Text ist wie beim Server
    ///   eine leere Zeile 0; ob ein Text leer aussieht, entscheidet die Ansicht.
    public init(description: String?) {
        lines = description.map { text in
            Self.split(text).enumerated().map { index, raw in Line(index: index, raw: raw, item: Self.item(in: raw)) }
        } ?? []
        items = lines.compactMap { line in
            line.item.map { Point(index: line.index, raw: line.raw, isChecked: $0.isChecked, text: $0.text) }
        }
    }

    private static func split(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar {
            case "\r":
                if pending == "\n" { pending = scalars.next() }
                lines.append(String(current))
                current = .init()
            case "\n":
                lines.append(String(current))
                current = .init()
            default:
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    private static func item(in line: String) -> Item? {
        let scalars = Array(line.unicodeScalars)
        var at = 0
        while at < scalars.count, at < 4, scalars[at] == " " { at += 1 }
        guard at <= 3, at < scalars.count, "-*+".unicodeScalars.contains(scalars[at]) else { return nil }
        at += 1
        let afterMarker = at
        while at < scalars.count, isSpace(scalars[at]) { at += 1 }
        guard at > afterMarker, at + 2 < scalars.count, scalars[at] == "[", scalars[at + 2] == "]" else { return nil }
        let isChecked: Bool
        switch scalars[at + 1] {
        case " ": isChecked = false
        case "x", "X": isChecked = true
        default: return nil
        }
        at += 3
        let afterBox = at
        while at < scalars.count, isSpace(scalars[at]) { at += 1 }
        guard at > afterBox else { return nil }
        // `.` in JavaScript trifft keinen Zeilentrenner, `\r` und `\n` hat `split` schon entfernt.
        let rest = scalars[at...]
        guard !rest.contains("\u{2028}"), !rest.contains("\u{2029}") else { return nil }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: rest)
        return Item(isChecked: isChecked, text: String(text))
    }

    /// `\s` in JavaScript: ECMAScript WhiteSpace und LineTerminator.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
}
