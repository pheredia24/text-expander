import XCTest
@testable import TextExpander

final class ReplacementSequenceTests: XCTestCase {
    @MainActor
    func testEmojiInsertionWaitsForPendingBackspaces() {
        var draft = ".ok"
        var pendingBackspaces = 0
        var scheduledInsertion: (@MainActor () -> Void)?

        ReplacementSequence.perform(
            deleting: 3,
            postBackspace: { pendingBackspaces += 1 },
            insert: { draft.append("👌") },
            schedule: { delay, action in
                XCTAssertGreaterThan(delay, 0)
                scheduledInsertion = action
            }
        )

        // Posting a key does not mean the target app has processed it. The
        // insertion must yield while the editor consumes its queued deletions.
        XCTAssertEqual(draft, ".ok")
        XCTAssertEqual(pendingBackspaces, 3)
        XCTAssertNotNil(scheduledInsertion)
        for _ in 0..<pendingBackspaces {
            draft.removeLast()
        }
        scheduledInsertion?()
        XCTAssertEqual(draft, "👌")
    }

    @MainActor
    func testDelimiterExpansionPreservesEarlierTextAndEmojiSequences() {
        var draft = "Before .wave "
        var pendingBackspaces = 0
        var scheduledInsertion: (@MainActor () -> Void)?

        ReplacementSequence.perform(
            deleting: ".wave ".count,
            postBackspace: { pendingBackspaces += 1 },
            insert: { draft.append("👋🏽 ") },
            schedule: { _, action in scheduledInsertion = action }
        )

        XCTAssertEqual(draft, "Before .wave ")
        XCTAssertEqual(pendingBackspaces, ".wave ".count)
        for _ in 0..<pendingBackspaces {
            draft.removeLast()
        }
        scheduledInsertion?()
        XCTAssertEqual(draft, "Before 👋🏽 ")
    }
}
