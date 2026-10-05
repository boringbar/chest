import AppKit
import ApplicationServices

/// The two permissions Chest needs.
///
/// - Accessibility: to see where menu bar items are, and to open one from the drawer.
/// - Full Disk Access: to switch apps in Control Center's "Allow in the Menu Bar" list,
///   which macOS keeps in a protected place.
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasFullDiskAccess: Bool { MenuBarSwitches.hasAccess }
    static var allGranted: Bool { hasAccessibility && hasFullDiskAccess }

    /// Adds Chest to the Accessibility list and shows the system prompt.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("Privacy_Accessibility")
    }

    static func openFullDiskAccess() {
        open("Privacy_AllFiles")
    }

    /// Gets Chest listed under Full Disk Access, so the user finds it there ready to switch on
    /// instead of hunting for it with “+”. Call first thing at launch.
    ///
    /// macOS lists an app only after it has tried to open a place that permission guards.
    /// Opening the Mail folder does; the privacy database and Safari's files do not. Reading
    /// Control Center's container is denied without listing the app, and macOS then keeps
    /// denying that process without asking again, so this must come before any other access
    /// (measured on macOS 27.0.1). Nothing is read: the attempt alone is what counts.
    static func announceFullDiskAccessUse() {
        let descriptor = Darwin.open(NSHomeDirectory() + "/Library/Mail", O_RDONLY)
        if descriptor >= 0 { close(descriptor) }
    }

    private static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
