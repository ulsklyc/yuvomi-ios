import Testing
import YuvomiCore

@Suite struct PairingCodeTests {
    @Test(arguments: [
        ("acdefghjk3", "ACDEF GHJK3"),
        ("ACDE-FGHJK3", "ACDEF GHJK3"),
        ("acd", "ACD"),
        ("acdef", "ACDEF"),
        ("acdefg", "ACDEF G"),
        ("", ""),
    ])
    func groupsTheCodeInFivesForDisplay(_ input: String, _ shown: String) {
        #expect(PairingCode.grouped(input) == shown)
    }
}
