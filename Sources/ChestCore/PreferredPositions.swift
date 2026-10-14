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
    /// The keys of the items of `bundleID`: `status:<bundle ID>::<autosave name>`, or a system
    /// item's `module:<key>` (see `SystemItems`).
    public static func keys(of bundleID: String, in positions: [String: Double]) -> [String] {
        if let item = SystemItems.item(id: bundleID) {
            return positions[item.positionKey] == nil ? [] : [item.positionKey]
        }
        let prefix = "status:\(bundleID)::"
        return positions.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The position of the first item of `bundleID`.
    public static func position(of bundleID: String, in positions: [String: Double]) -> Double? {
        keys(of: bundleID, in: positions).first.flatMap { positions[$0] }
    }

    /// The app an item's key names: `status:<bundle ID>::<autosave name>`, or the system item
    /// a `module:<key>` is. MenuBarAgent's other items (the clock, …) name none.
    public static func bundleID(ofKey key: String) -> String? {
        if let item = SystemItems.item(positionKey: key) { return item.id }
        guard key.hasPrefix("status:"), let end = key.range(of: "::") else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: 7)..<end.lowerBound])
    }

    /// A position at least as far left as an item drawn from `minX` in a menu bar ending at
    /// `barMaxX`. MenuBarAgent places an item it keeps no position for (a new one) as if its
    /// position were where it is drawn: the distance from the bar's right end to the item's
    /// right edge, less the system items' share (44 points on macOS 27.0.1, which depends on
    /// what they show). Measuring to the item's left edge instead stays past that.
    public static func estimate(itemMinX minX: Double, barMaxX: Double) -> Double {
        barMaxX - minX
    }

    /// Where the dot goes to sit left of the items in `past`: one point past the leftmost of
    /// their positions and of `estimates` (see `estimate(itemMinX:barMaxX:)`), or where it is
    /// if that is further left. The `hidden` apps' items, kept left of the dot, move further
    /// left where the dot would pass them, in their order.
    /// - Returns: the dot's position, and the hidden items' keys with their new positions.
    public static func dotPlacement(dotKey: String, past: [String], estimates: [Double] = [], hidden: Set<String>, in positions: [String: Double]) -> (dot: Double?, moved: [String: Double]) {
        let current = positions[dotKey]
        let leftmost = (past.compactMap { positions[$0] } + estimates).max()
        guard let dot = [current, leftmost.map { $0 + 1 }].compactMap({ $0 }).max() else { return (nil, [:]) }
        var moved: [String: Double] = [:]
        var floor = dot
        // Right to left, each at least a point past the one before.
        let isHidden = { (key: String) in bundleID(ofKey: key).map(hidden.contains) ?? false }
        for (key, position) in positions.filter({ isHidden($0.key) }).sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            let new = max(position, floor + 1)
            if new != position { moved[key] = new }
            floor = new
        }
        return (dot, moved)
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
