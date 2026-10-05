import Foundation
import ChestCore

/// The positions MenuBarAgent keeps for menu bar items (see `PreferredPositions`). Writing an
/// item's position while it is switched off places it there when it is switched back on.
enum MenuBarPositions {
    private static let key = "TrailingItemPreferredPositions"
    /// An absolute path, as with the allow list: CFPreferences uses that very file and still
    /// tells MenuBarAgent through cfprefsd.
    private static let domain = NSHomeDirectory()
        + "/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"

    /// Every item's position, by key.
    static func all() -> [String: Double] {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Moves every item of `bundleID` to `position`. Returns false if MenuBarAgent has no
    /// position for the app yet, so there is nothing to move.
    @discardableResult
    static func set(_ position: Double, for bundleID: String) -> Bool {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard var dictionary = value as? [String: Any] else { return false }
        let keys = PreferredPositions.keys(of: bundleID, in: dictionary.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        guard !keys.isEmpty else { return false }
        // Several items keep their order, a hair apart.
        for (index, key) in keys.enumerated() { dictionary[key] = position + Double(index) * 0.01 }
        CFPreferencesSetValue(key as CFString, dictionary as CFDictionary, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        log("position of \(bundleID) set to \(position)")
        return true
    }
}
