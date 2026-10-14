import AppKit
import ChestCore

/// Where Chest keeps an app's items, both persisted in user defaults in the order they went in.
enum Section {
    /// In the drawer that hangs under the dot.
    case drawer
    /// In the menu bar left of the dot, shown only while the chest is open.
    case hidden
}

/// The apps Chest hides, and where each one goes when it is shown.
@MainActor
final class ChestStore {
    private static let drawerKey = "chestItems"
    private static let hiddenKey = "hiddenItems"
    private let defaults = UserDefaults.standard

    /// The apps in the drawer.
    private(set) var items: [String] {
        didSet { defaults.set(items, forKey: Self.drawerKey) }
    }

    /// The apps hidden left of the dot.
    private(set) var hidden: [String] {
        didSet { defaults.set(hidden, forKey: Self.hiddenKey) }
    }

    var onChange: (() -> Void)?

    init() {
        items = defaults.stringArray(forKey: Self.drawerKey) ?? []
        hidden = defaults.stringArray(forKey: Self.hiddenKey) ?? []
    }

    /// Every app Chest hides, wherever it goes.
    var all: Set<String> { Set(items).union(hidden) }

    func contains(_ bundleID: String) -> Bool { section(of: bundleID) != nil }

    func section(of bundleID: String) -> Section? {
        if items.contains(bundleID) { return .drawer }
        if hidden.contains(bundleID) { return .hidden }
        return nil
    }

    /// Puts the app in `section`, taking it out of the other one.
    func add(_ bundleID: String, to section: Section) {
        guard self.section(of: bundleID) != section else { return }
        items.removeAll { $0 == bundleID }
        hidden.removeAll { $0 == bundleID }
        switch section {
        case .drawer: items.append(bundleID)
        case .hidden: hidden.append(bundleID)
        }
        onChange?()
    }

    func remove(_ bundleID: String) {
        guard contains(bundleID) else { return }
        items.removeAll { $0 == bundleID }
        hidden.removeAll { $0 == bundleID }
        onChange?()
    }
}

/// Name and icon of an app in the chest.
struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage
    let isRunning: Bool

    /// System items, which have no app icon of their own: Spotlight and Text Input belong to
    /// background services, Weather to a login item, the others to MenuBarAgent.
    private static let systemItems: [String: (name: String, symbol: String)] = {
        var items = Dictionary(uniqueKeysWithValues: SystemItems.all.map { ($0.id, ($0.name, $0.symbol)) })
        items["com.apple.campo"] = ("Spotlight", "magnifyingglass")
        items["com.apple.TextInputMenuAgent"] = ("Text Input", "keyboard")
        items["com.apple.weather.menu"] = ("Weather", "cloud.sun")
        return items
    }()

    @MainActor
    init(bundleID: String) {
        self.bundleID = bundleID
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let system = Self.systemItems[bundleID] {
            // MenuBarAgent's own items have no process, and Weather's login item runs only
            // while its item is shown; they are always there.
            isRunning = running != nil || SystemItems.item(id: bundleID) != nil || MenuBarSwitches.isLoginItem(bundleID)
            name = system.name
            let symbol = NSImage(systemSymbolName: system.symbol, accessibilityDescription: system.name)
                ?? NSImage(systemSymbolName: "circle", accessibilityDescription: system.name)!
            icon = symbol.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? symbol
            icon.isTemplate = true
            return
        }
        isRunning = running != nil
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        name = running?.localizedName
            ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }
}
