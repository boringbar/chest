import Foundation

/// The positions MenuBarAgent keeps for menu bar items, in the `com.apple.MenuBar` group
/// container under `TrailingItemPreferredPositions`:
///
///     { "status:com.example.app::Item-0": 213, "module:Clock": 0, … }
///
/// A position is a distance from the right end of the menu bar, so a larger one sits further
/// left. An item that is switched back on goes to its position, which places it without
/// dragging it there.
public enum PreferredPositions {
    /// The keys of the items of `bundleID`: `status:<bundle ID>::<autosave name>`.
    public static func keys(of bundleID: String, in positions: [String: Double]) -> [String] {
        let prefix = "status:\(bundleID)::"
        return positions.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The position of the first item of `bundleID`.
    public static func position(of bundleID: String, in positions: [String: Double]) -> Double? {
        keys(of: bundleID, in: positions).first.flatMap { positions[$0] }
    }

    /// A position between the item on the left (`left`, the larger) and the one on the right.
    /// With one neighbour unknown it stays next to the known one; with neither, nil.
    public static func between(_ left: Double?, and right: Double?) -> Double? {
        switch (left, right) {
        case let (left?, right?): (left + right) / 2
        case let (left?, nil): max(left - 1, left / 2)
        case let (nil, right?): right + 1
        case (nil, nil): nil
        }
    }
}
