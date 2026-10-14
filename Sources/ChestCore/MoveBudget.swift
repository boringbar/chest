import Foundation

/// How often the dot may go past the same app's items. An app that keeps taking its item away
/// and putting it back (one shown only while something is going on) gets no position saved
/// for it, so the item comes back at the left end each time, and the dot would blink each
/// time it went past it. Measured on macOS 27.0.1.
public struct MoveBudget: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var moves: [String: [Date]] = [:]

    public init(limit: Int = 3, window: TimeInterval = 600) {
        self.limit = limit
        self.window = window
    }

    /// Whether the dot may still go past `bundleID`'s items.
    public func allows(_ bundleID: String, at now: Date) -> Bool {
        (moves[bundleID] ?? []).filter { now.timeIntervalSince($0) < window }.count < limit
    }

    /// Counts a move past the items of `bundleIDs`, once per app.
    public mutating func record(_ bundleIDs: Set<String>, at now: Date) {
        for bundleID in bundleIDs {
            moves[bundleID] = (moves[bundleID] ?? []).filter { now.timeIntervalSince($0) < window } + [now]
        }
        // Apps that have not come back within the window are forgotten.
        moves = moves.filter { $0.value.contains { now.timeIntervalSince($0) < window } }
    }
}
