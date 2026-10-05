import Foundation
import ChestCore

/// Shows and hides apps' menu bar items through System Settings' own switches, which
/// MenuBarAgent applies at once. Unlike the assessment-mode restriction other menu bar
/// managers use on macOS 27, they leave Focus, the camera and microphone indicator,
/// Notification Center and apps outside /Applications alone.
enum MenuBarSwitches {
    enum Result: Equatable {
        case done
        /// MenuBarAgent has no entry for these apps yet, so they cannot be switched.
        case untracked(Set<String>)
        /// The list cannot be read: Full Disk Access is off.
        case noAccess
    }

    // MARK: App items: Control Center's "Allow in the Menu Bar" list

    private static let key = "trackedApplications"
    private static let containerPreferences = NSHomeDirectory()
        + "/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences"
    /// An absolute path makes CFPreferences use that very file instead of a domain of our
    /// own. The write still goes through cfprefsd, which tells MenuBarAgent about it.
    private static let domain = containerPreferences + "/group.com.apple.controlcenter"

    /// Whether the list can be read. The container is protected: it takes Full Disk Access.
    static var hasAccess: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: containerPreferences)) != nil
    }

    // MARK: System items with a switch of their own

    /// System items are not in the list. Each has a checkbox under System Settings › Menu Bar ›
    /// Menu Bar Controls backed by a preference, keyed here by the bundle ID that owns the item
    /// in the menu bar. These need no Full Disk Access. To add one, toggle its checkbox and
    /// compare the preferences before and after; see docs/APPROACH.md.
    private static let systemSwitches: [String: (domain: String, key: String)] = [
        // macOS 27's Spotlight item belongs to the campo service.
        "com.apple.campo": ("com.apple.Spotlight", "MenuItemHidden"),
    ]

    static func isSystemItem(_ bundleID: String) -> Bool {
        systemSwitches[bundleID] != nil
    }

    // MARK: Switching

    /// Shows (`allowed`) or hides the menu bar items of `bundleIDs`.
    @discardableResult
    static func set(_ allowed: Bool, for bundleIDs: Set<String>) -> Result {
        var apps = bundleIDs
        for bundleID in bundleIDs {
            guard let item = systemSwitches[bundleID] else { continue }
            apps.remove(bundleID)
            CFPreferencesSetValue(item.key as CFString, !allowed as CFBoolean, item.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(item.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        guard !apps.isEmpty else { return .done }
        guard let list = load() else { return hasAccess ? .untracked(apps) : .noAccess }
        let result = AllowList.setting(allowed, for: apps, in: list)
        if result.changed { store(result.list) }
        log("allowed=\(allowed) apps=\(apps.sorted()) missing=\(result.missing.sorted()) changed=\(result.changed)")
        return result.missing.isEmpty ? .done : .untracked(result.missing)
    }

    /// Whether MenuBarAgent has an entry for the app, so it can be switched.
    static func isListed(_ bundleID: String) -> Bool {
        isSystemItem(bundleID) || (load().map { AllowList.entries(in: $0).contains { $0.bundleID == bundleID } } ?? false)
    }

    private static func load() -> [Any]? {
        guard let data = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any]
    }

    private static func store(_ list: [Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
        CFPreferencesSetValue(key as CFString, data as CFData, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Debug logging to stderr; silent in release builds.
func log(_ message: @autoclosure () -> String) {
    #if DEBUG
    FileHandle.standardError.write(Data("[Chest] \(message())\n".utf8))
    #endif
}
