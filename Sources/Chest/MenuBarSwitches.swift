import AppKit
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
        /// The list cannot be read: its file was not picked (`FileAccess`).
        case noAccess
    }

    // MARK: App items: Control Center's "Allow in the Menu Bar" list

    private static let key = "trackedApplications"
    private static let containerPreferences = NSHomeDirectory()
        + "/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences"
    /// An absolute path makes CFPreferences use that very file instead of a domain of our
    /// own. The write still goes through cfprefsd, which tells MenuBarAgent about it.
    private static let domain = containerPreferences + "/group.com.apple.controlcenter"

    /// Whether the list can be read. The container is protected; Chest gets at this one file
    /// once the user picks it, and the folder stays closed.
    static var hasAccess: Bool { FileAccess.canRead(.allowList) }

    // MARK: System items with a switch of their own

    /// System items are not in the list. Each has a checkbox under System Settings › Menu Bar ›
    /// Menu Bar Controls backed by a preference. These need no file access. To add one,
    /// toggle its checkbox and compare the preferences before and after; see docs/APPROACH.md.
    ///
    /// Most are items MenuBarAgent draws itself, in `SystemItems`. Spotlight and Text Input
    /// belong to processes of their own, keyed here by their bundle IDs, and each has a flag.
    /// Weather's belongs to a login item; see `loginItems`.
    private static let flagSwitches: [String: (domain: String, key: String, currentHost: Bool, hides: Bool)] = [
        // macOS 27's Spotlight item belongs to the campo service.
        "com.apple.campo": ("com.apple.Spotlight", "MenuItemHidden", true, true),
        "com.apple.TextInputMenuAgent": ("com.apple.TextInputMenu", "visible", false, false),
    ]

    /// Weather's item belongs to a login item of the Weather app, run by launchd for the
    /// login session. Its checkbox has a key in `com.apple.controlcenter` like those of
    /// `SystemItems`, but the item does not follow it: System Settings writes the key and
    /// also unregisters or registers the login item. Chest writes the key, so System Settings
    /// shows the choice and `isOn` reads it, then stops the login item's job (`launchctl
    /// bootout`; killing the process alone gets it restarted) or launches the app. Login
    /// starts the job again; Chest switches it off again. Measured on macOS 27.0.1.
    private static let loginItems: [String: (key: String, label: String, app: String)] = [
        "com.apple.weather.menu": ("Weather", "com.apple.weather.menu",
                                   "/System/Applications/Weather.app/Contents/Library/LoginItems/WeatherMenu.app"),
    ]

    private static let controlCenter = "com.apple.controlcenter"
    /// The values of `SystemItems` keys that hiding replaced, to put back; in Chest's own
    /// preferences, so they outlast a crash.
    private static let savedValuesKey = "systemItemValues"

    static func isSystemItem(_ bundleID: String) -> Bool {
        flagSwitches[bundleID] != nil || SystemItems.item(id: bundleID) != nil || loginItems[bundleID] != nil
    }

    /// The Control Center key of a system item, or nil for one switched otherwise.
    private static func controlCenterKey(_ bundleID: String) -> String? {
        SystemItems.item(id: bundleID)?.key ?? loginItems[bundleID]?.key
    }

    /// Whether the item belongs to a login item, which login starts again whatever its
    /// switch says.
    static func isLoginItem(_ bundleID: String) -> Bool {
        loginItems[bundleID] != nil
    }

    private static func setControlCenterKey(_ key: String, shown: Bool) {
        let controlCenter = controlCenter as CFString
        CFPreferencesSynchronize(controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let current = (CFPreferencesCopyValue(key as CFString, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
        var saved = UserDefaults.standard.dictionary(forKey: savedValuesKey) as? [String: Int] ?? [:]
        let result = SystemItems.switching(shown, current: current, saved: saved[key])
        saved[key] = result.saved
        UserDefaults.standard.set(saved, forKey: savedValuesKey)
        let value: CFPropertyList?
        switch result.write {
        case .keep: return
        case .set(let number): value = number as CFNumber
        case .remove: value = nil
        }
        CFPreferencesSetValue(key as CFString, value, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        log("\(key): \(current.map(String.init) ?? "missing") -> \(result.write)")
    }

    private static func setLoginItem(_ bundleID: String, shown: Bool) {
        guard let item = loginItems[bundleID] else { return }
        setControlCenterKey(item.key, shown: shown)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if shown {
            guard running.isEmpty else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.app), configuration: configuration) { _, error in
                if let error { log("\(bundleID) didn't launch: \(error)") }
            }
        } else {
            // launchd restarts the job's process, so the job goes first. One Chest launched
            // is not launchd's and is quit.
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout", "gui/\(getuid())/\(item.label)"]
            launchctl.standardError = FileHandle.nullDevice
            if (try? launchctl.run()) != nil { launchctl.waitUntilExit() }
            running.forEach { $0.terminate() }
        }
    }

    // MARK: Switching

    /// Shows (`allowed`) or hides the menu bar items of `bundleIDs`.
    @discardableResult
    static func set(_ allowed: Bool, for bundleIDs: Set<String>) -> Result {
        var apps = bundleIDs
        for bundleID in bundleIDs {
            if let item = SystemItems.item(id: bundleID) {
                apps.remove(bundleID)
                setControlCenterKey(item.key, shown: allowed)
            } else if loginItems[bundleID] != nil {
                apps.remove(bundleID)
                setLoginItem(bundleID, shown: allowed)
            } else if let item = flagSwitches[bundleID] {
                apps.remove(bundleID)
                let value = allowed != item.hides
                let host = item.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
                CFPreferencesSetValue(item.key as CFString, value as CFBoolean, item.domain as CFString, kCFPreferencesCurrentUser, host)
                CFPreferencesSynchronize(item.domain as CFString, kCFPreferencesCurrentUser, host)
            }
        }
        guard !apps.isEmpty else { return .done }
        guard let list = load() else { return hasAccess ? .untracked(apps) : .noAccess }
        let result = AllowList.setting(allowed, for: apps, in: list)
        if result.changed { store(result.list) }
        log("allowed=\(allowed) apps=\(apps.sorted()) missing=\(result.missing.sorted()) changed=\(result.changed)")
        return result.missing.isEmpty ? .done : .untracked(result.missing)
    }

    /// Whether the item's own switch says shown, or nil if it can't be read. An item Chest
    /// hides that is drawn with its switch on was switched back on outside Chest: from System
    /// Settings, where Chest's hiding shows as the checkbox or switch being off.
    static func isOn(_ bundleID: String) -> Bool? {
        if let key = controlCenterKey(bundleID) {
            let controlCenter = controlCenter as CFString
            CFPreferencesSynchronize(controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            let value = (CFPreferencesCopyValue(key as CFString, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
            // A missing key is the default; the item is drawn, so that shows it.
            return value != SystemItems.hidden
        }
        if let item = flagSwitches[bundleID] {
            let host = item.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
            CFPreferencesSynchronize(item.domain as CFString, kCFPreferencesCurrentUser, host)
            guard let value = CFPreferencesCopyValue(item.key as CFString, item.domain as CFString, kCFPreferencesCurrentUser, host) as? Bool else { return nil }
            return value != item.hides
        }
        return load().flatMap { AllowList.entries(in: $0).first { $0.bundleID == bundleID }?.isAllowed }
    }

    /// Forgets the value Chest kept to put back for a system item that is no longer Chest's.
    static func forget(_ bundleID: String) {
        guard let key = controlCenterKey(bundleID),
              var saved = UserDefaults.standard.dictionary(forKey: savedValuesKey) as? [String: Int] else { return }
        saved[key] = nil
        UserDefaults.standard.set(saved, forKey: savedValuesKey)
    }

    /// Whether MenuBarAgent has an entry for the app, so it can be switched.
    static func isListed(_ bundleID: String) -> Bool {
        isSystemItem(bundleID) || (load().map { AllowList.entries(in: $0).contains { $0.bundleID == bundleID } } ?? false)
    }

    private static func load() -> [Any]? {
        // CFPreferences keeps what it read, and MenuBarAgent adds entries while Chest runs. A
        // list written back from a stale copy would drop them, and MenuBarAgent would take
        // those apps for new ones.
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
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
