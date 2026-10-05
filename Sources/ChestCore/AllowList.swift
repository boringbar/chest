import Foundation

/// The format of Control Center's "Allow in the Menu Bar" list (System Settings › Menu Bar).
///
/// macOS 27 stores it as a binary property list under the key `trackedApplications`: an array
/// that alternates keys and entries.
///
///     [ {bundle: {_0: "com.example.app"}},
///       {isAllowed: true, location: {…}, menuItemLocations: [{…}]},
///       … ]
///
/// MenuBarAgent creates every entry itself and matches items by `menuItemLocations`. An entry
/// written from scratch is ignored and replaced, so only `isAllowed` of an existing entry is
/// ever changed, and every other field is kept exactly as read.
public enum AllowList {
    public struct Entry: Equatable, Sendable {
        public let bundleID: String
        public let isAllowed: Bool
    }

    /// Every entry with a bundle identifier, in list order.
    public static func entries(in list: [Any]) -> [Entry] {
        stride(from: 0, to: list.count - 1, by: 2).compactMap { index in
            guard let bundleID = bundleID(ofKey: list[index]),
                  let entry = list[index + 1] as? [String: Any] else { return nil }
            return Entry(bundleID: bundleID, isAllowed: entry["isAllowed"] as? Bool ?? true)
        }
    }

    /// `list` with `isAllowed` set for the apps in `bundleIDs` that have an entry.
    /// - Returns: the new list, whether anything changed, and the apps without an entry.
    public static func setting(
        _ allowed: Bool,
        for bundleIDs: Set<String>,
        in list: [Any]
    ) -> (list: [Any], changed: Bool, missing: Set<String>) {
        var list = list
        var missing = bundleIDs
        var changed = false
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            guard let bundleID = bundleID(ofKey: list[index]), bundleIDs.contains(bundleID),
                  var entry = list[index + 1] as? [String: Any] else { continue }
            missing.remove(bundleID)
            guard entry["isAllowed"] as? Bool != allowed else { continue }
            entry["isAllowed"] = allowed
            list[index + 1] = entry
            changed = true
        }
        return (list, changed, missing)
    }

    static func bundleID(ofKey key: Any) -> String? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}
