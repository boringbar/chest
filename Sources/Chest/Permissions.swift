import AppKit
import ApplicationServices

/// What Chest needs.
///
/// - Accessibility: to see where menu bar items are, and to open one from the drawer.
/// - The two protected files it changes, picked once by the user (`FileAccess`): Control
///   Center's "Allow in the Menu Bar" list and MenuBarAgent's positions. Full Disk Access
///   opens them too, so a Chest it was granted to before keeps working.
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static func hasFile(_ file: ProtectedFile) -> Bool { FileAccess.canRead(file) }
    static var allGranted: Bool { hasAccessibility && ProtectedFile.allCases.allSatisfy(hasFile) }

    /// Adds Chest to the Accessibility list and shows the system prompt.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("Privacy_Accessibility")
    }

    private static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
