import Foundation

/// Keeps replacement ordering in one place so it can be checked without sending keys.
@MainActor
enum ReplacementSequence {
    private static let deletionSettleDelay: TimeInterval = 0.08

    static func perform(
        deleting count: Int,
        postBackspace: () -> Void,
        insert: @escaping @MainActor () -> Void,
        schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    ) {
        for _ in 0..<count {
            postBackspace()
        }
        // CGEvent.post only queues the key. Editors such as WhatsApp can
        // process a paste before their queued backspaces have finished.
        schedule(deletionSettleDelay, insert)
    }
}
