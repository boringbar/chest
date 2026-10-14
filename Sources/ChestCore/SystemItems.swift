import Foundation

/// The system items Chest can put away: those under System Settings › Menu Bar › Menu Bar
/// Controls that MenuBarAgent draws itself (Wi-Fi, Sound, …).
///
/// MenuBarAgent names each by the identifier of its menu extra, `com.apple.menuextra.<name>`,
/// which Chest uses as its bundle ID. Each checkbox is a key in Control Center's preferences
/// for the current host (`com.apple.controlcenter`): 8 hides the item; 2 shows it (or shows it
/// when active, for items with that choice) and 18 always shows it. A key that is missing
/// means the item's default. MenuBarAgent applies a change at once. Its position is kept as
/// `module:<key>`. Measured on macOS 27.0.1.
///
/// Spotlight, Text Input and Weather are not here: their items belong to processes of their
/// own and are switched otherwise (see `MenuBarSwitches`).
public struct SystemItem: Sendable, Equatable {
    /// The identifier of its menu extra, which Chest uses as its bundle ID.
    public let id: String
    public let name: String
    /// An SF Symbol for the drawer.
    public let symbol: String
    /// Its checkbox's key in `com.apple.controlcenter` (current host).
    public let key: String

    /// Its key among MenuBarAgent's positions.
    public var positionKey: String { "module:\(key)" }
}

public enum SystemItems {
    /// The value of a checkbox's key that hides the item.
    public static let hidden = 8

    /// Clock and Control Center have no checkbox and stay. Time Machine and VPN have one, but
    /// showed no item on the machine this was measured on, so their names are not known;
    /// Battery and the others of a portable Mac were not there either.
    public static let all: [SystemItem] = [
        item("wifi", "Wi-Fi", "wifi", "WiFi"),
        item("bluetooth", "Bluetooth", "antenna.radiowaves.left.and.right", "Bluetooth"),
        item("airdrop", "AirDrop", "dot.radiowaves.up.forward", "AirDrop"),
        item("focusmode", "Focus", "moon.fill", "FocusModes"),
        item("screen-mirroring", "Screen Mirroring", "rectangle.on.rectangle", "ScreenMirroring"),
        item("display", "Display", "sun.max", "Display"),
        item("sound", "Sound", "speaker.wave.2.fill", "Sound"),
        item("now-playing", "Now Playing", "play.circle", "NowPlaying"),
        item("user", "Fast User Switching", "person.crop.circle", "UserSwitcher"),
        item("timer", "Timer", "timer", "Timer"),
    ]

    private static func item(_ name: String, _ title: String, _ symbol: String, _ key: String) -> SystemItem {
        SystemItem(id: "com.apple.menuextra.\(name)", name: title, symbol: symbol, key: key)
    }

    /// What to do to a checkbox's key.
    public enum Write: Equatable, Sendable {
        case keep
        case set(Int)
        /// Back to the item's default.
        case remove
    }

    /// Stands for a key that was missing, among the values kept to put back.
    public static let missing = -1

    /// How to hide (`shown` false) or show an item whose key is `current` (nil when missing),
    /// with `saved` the value Chest kept when it hid the item, if it did. Hiding keeps the
    /// value it replaces, so showing puts back the user's choice (shown when active, always
    /// shown, or the default) rather than one of its own.
    /// - Returns: what to write, and the value to keep from now on.
    public static func switching(_ shown: Bool, current: Int?, saved: Int?) -> (write: Write, saved: Int?) {
        if !shown {
            // Already hidden: by Chest, whose value is kept already, or by the user.
            guard current != hidden else { return (.keep, saved) }
            return (.set(hidden), current ?? missing)
        }
        // Shown already, by the user from System Settings meanwhile.
        guard current == hidden else { return (.keep, nil) }
        switch saved {
        case nil: return (.set(2), nil)
        case missing: return (.remove, nil)
        case let value?: return (.set(value), nil)
        }
    }

    public static func item(id: String) -> SystemItem? {
        all.first { $0.id == id }
    }

    public static func item(positionKey: String) -> SystemItem? {
        all.first { $0.positionKey == positionKey }
    }
}
