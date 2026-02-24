import XCTest
@testable import TextExpander

final class ExpansionLogicTests: XCTestCase {
    func testDelimiterOnlyDoesNotExpandOnNonDelimiter() {
        XCTAssertFalse(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: "a"))
        XCTAssertFalse(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: "9"))
        XCTAssertFalse(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: "_"))
    }

    func testDelimiterOnlyExpandsOnDelimiter() {
        XCTAssertTrue(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: " "))
        XCTAssertTrue(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: "."))
        XCTAssertTrue(ExpansionLogic.shouldAttemptExpansion(mode: .delimiterOnly, typedCharacter: "\n"))
    }

    func testInstantAlwaysAttemptsExpansion() {
        XCTAssertTrue(ExpansionLogic.shouldAttemptExpansion(mode: .instant, typedCharacter: "a"))
        XCTAssertTrue(ExpansionLogic.shouldAttemptExpansion(mode: .instant, typedCharacter: "."))
    }

    func testBoundaryRuleBlocksPartialSuffixForWordAbbreviation() {
        let snippetMap = ["joy": "😂"]
        XCTAssertNil(ExpansionLogic.bestAbbreviationMatch(in: ".joy", snippetMap: snippetMap))
        XCTAssertNotNil(ExpansionLogic.bestAbbreviationMatch(in: " joy", snippetMap: snippetMap))
    }

    func testLongestMatchWinsForOverlappingAbbreviations() {
        let snippetMap = [
            ".a": "A",
            ".abc": "ABC",
        ]

        let match = ExpansionLogic.bestAbbreviationMatch(in: ".abc", snippetMap: snippetMap)
        XCTAssertEqual(match?.abbreviation, ".abc")
        XCTAssertEqual(match?.phrase, "ABC")
    }
    func testSlotTemplateKeepsNamedSlotsUniqueAndOrdered() {
        let fields = SlotTemplateLogic.slotFields(in: "Hi {{name}}, let's talk about {{topic}} with {{name}}.")
        XCTAssertEqual(fields.map(\.label), ["name", "topic"])
    }

    func testSlotTemplateBuildsAnonymousSlots() {
        let fields = SlotTemplateLogic.slotFields(in: "{{}} and {{ }}")
        XCTAssertEqual(fields.map(\.label), ["Slot 1", "Slot 2"])
        XCTAssertNotEqual(fields[0].key, fields[1].key)
    }

    func testSlotTemplateAppliesValuesToAllOccurrences() {
        let template = "Hello {{name}}, topic: {{topic}}. Bye {{name}}."
        let resolved = SlotTemplateLogic.applySlotValues(
            [
                "name": "Pablo",
                "topic": "slots",
            ],
            to: template
        )

        XCTAssertEqual(resolved, "Hello Pablo, topic: slots. Bye Pablo.")
    }
}
