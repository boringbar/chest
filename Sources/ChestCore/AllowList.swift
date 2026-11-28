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
///
/// An entry is keyed by the app System Settings shows, which need not be the process that
/// draws the item: a helper inside the app's bundle (`AirBuddy.app/…/AirBuddyHelper.app`,
/// Apple's `PasswordsMenuBarExtra`) gets an entry keyed by the outer app, with the helper's
/// bundle ID only under `menuItemLocations`. Measured on macOS 27 with a login-item fixture in
/// /Applications; an ad-hoc signed one outside it got an entry keyed by the helper itself. So
/// an app goes by the entry keyed by it, or, having none, by the entries listing it as an item
/// location. An app with an entry of its own is never switched through another app's: that
/// would switch the other app's items too, and an app was always switched by its own alone.
public enum AllowList {
    public struct Entry: Equatable, Sendable {
        /// The app the entry is keyed by, the one System Settings shows.
        public let bundleID: String
        public let isAllowed: Bool
        /// The bundle IDs of the processes whose items the entry switches, which can differ
        /// from `bundleID`. Locations given as a binary path are left out.
        public let itemBundleIDs: [String]

        public init(bundleID: String, isAllowed: Bool, itemBundleIDs: [String] = []) {
            self.bundleID = bundleID
            self.isAllowed = isAllowed
            self.itemBundleIDs = itemBundleIDs
        }
    }

    /// Every entry with a bundle identifier, in list order.
    public static func entries(in list: [Any]) -> [Entry] {
        stride(from: 0, to: list.count - 1, by: 2).compactMap { index in
            guard let bundleID = bundleID(ofKey: list[index]),
                  let entry = list[index + 1] as? [String: Any] else { return nil }
            return Entry(bundleID: bundleID, isAllowed: entry["isAllowed"] as? Bool ?? true,
                         itemBundleIDs: itemBundleIDs(of: entry))
        }
    }

    /// The entries that switch the items of `bundleID`: its own, or, with none, those of the
    /// apps listing it as an item location (the app it is a helper of).
    static func switching(_ bundleID: String, in entries: [Entry]) -> [Entry] {
        let own = entries.filter { $0.bundleID == bundleID }
        return own.isEmpty ? entries.filter { $0.itemBundleIDs.contains(bundleID) } : own
    }

    /// The entry that switches the items of `bundleID`: its own, or the one of the app it is
    /// a helper of.
    public static func entry(for bundleID: String, in list: [Any]) -> Entry? {
        switching(bundleID, in: entries(in: list)).first
    }

    /// The app each helper is listed under, for the helpers drawing items for an app other
    /// than themselves, with no entry of their own.
    public static func listingApps(in list: [Any]) -> [String: String] {
        let entries = entries(in: list)
        let keys = Set(entries.map(\.bundleID))
        var apps: [String: String] = [:]
        for entry in entries {
            for helper in entry.itemBundleIDs where !keys.contains(helper) && apps[helper] == nil {
                apps[helper] = entry.bundleID
            }
        }
        return apps
    }

    /// Whether the items of `bundleID` are allowed, or nil if no entry switches them. When
    /// several do, `setting` switches them all; it counts as allowed if any of them is.
    public static func isAllowed(_ bundleID: String, in list: [Any]) -> Bool? {
        let matching = switching(bundleID, in: entries(in: list))
        return matching.isEmpty ? nil : matching.contains(where: \.isAllowed)
    }

    /// The other apps and helpers an entry of `bundleID` also switches: switching `bundleID`
    /// on or off switches them too. An app listed there that has an entry of its own goes by
    /// that one, so it does not share.
    public static func sharing(_ bundleID: String, in list: [Any]) -> Set<String> {
        let entries = entries(in: list)
        let keys = Set(entries.map(\.bundleID))
        var shared = Set<String>()
        for entry in switching(bundleID, in: entries) {
            shared.insert(entry.bundleID)
            shared.formUnion(entry.itemBundleIDs.filter { !keys.contains($0) })
        }
        shared.remove(bundleID)
        return shared
    }

    /// `list` with `isAllowed` set for the apps in `bundleIDs` that have an entry: keyed by
    /// them, or, for one with no entry of its own, listing it as an item location.
    /// - Returns: the new list, whether anything changed, and the apps without an entry.
    public static func setting(
        _ allowed: Bool,
        for bundleIDs: Set<String>,
        in list: [Any]
    ) -> (list: [Any], changed: Bool, missing: Set<String>) {
        var list = list
        var missing = bundleIDs
        var changed = false
        let keys = Set(entries(in: list).map(\.bundleID))
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            guard let key = bundleID(ofKey: list[index]),
                  var entry = list[index + 1] as? [String: Any] else { continue }
            let locations = itemBundleIDs(of: entry)
            let matched = bundleIDs.filter { $0 == key || (!keys.contains($0) && locations.contains($0)) }
            guard !matched.isEmpty else { continue }
            missing.subtract(matched)
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

    /// The bundle IDs among an entry's `menuItemLocations`, which have the same shape as a key.
    static func itemBundleIDs(of entry: [String: Any]) -> [String] {
        (entry["menuItemLocations"] as? [Any] ?? []).compactMap(bundleID(ofKey:))
    }
}
