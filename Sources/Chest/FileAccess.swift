import AppKit

/// The two files Chest changes, each in another app's protected container: Control Center's
/// "Allow in the Menu Bar" list, which hides items, and MenuBarAgent's positions, which place
/// them and keep the dot at the left end.
///
/// Full Disk Access opens both, but a file the user picks in an Open panel is enough: macOS
/// then lets Chest read and write that one file, through CFPreferences as well, and nothing
/// else in its container. The grant outlives a relaunch; a security-scoped bookmark of the
/// file is kept so it can be renewed at launch if macOS forgets it (measured on macOS 27.0.1).
enum ProtectedFile: CaseIterable {
    case allowList
    case positions

    var url: URL {
        switch self {
        case .allowList:
            URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        case .positions:
            URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
        }
    }

    /// How the setup window and notices name it.
    var title: String {
        switch self {
        case .allowList: "Allow in the Menu Bar"
        case .positions: "Menu bar layout"
        }
    }

    var detail: String {
        switch self {
        case .allowList:
            "To hide items, Chest uses macOS’s own “Allow in the Menu Bar” switches. Choose the file that holds them; Chest can open no other file there. Focus and the camera and microphone indicators stay visible."
        case .positions:
            "To keep the dot at the left end and put items back where you drop them. Choose the file where macOS keeps the order of the menu bar."
        }
    }

    fileprivate var bookmarkKey: String {
        switch self {
        case .allowList: "allowListBookmark"
        case .positions: "positionsBookmark"
        }
    }
}

extension Notification.Name {
    /// Posted when the user has picked one of the protected files.
    static let protectedFileGranted = Notification.Name("ChestProtectedFileGranted")
}

@MainActor
enum FileAccess {
    /// Whether Chest can open the file now: picked, or under Full Disk Access.
    nonisolated static func canRead(_ file: ProtectedFile) -> Bool {
        let descriptor = Darwin.open(file.url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Renews access to the files picked before, from their bookmarks. Call at launch,
    /// before reading either file.
    static func restore() {
        for file in ProtectedFile.allCases where !canRead(file) {
            guard let data = UserDefaults.standard.data(forKey: file.bookmarkKey) else { continue }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                log("bookmark of \(file.title) no longer resolves")
                continue
            }
            // Held for as long as Chest runs.
            _ = url.startAccessingSecurityScopedResource()
            if isStale { save(url, for: file) }
            log("\(file.title): access renewed from its bookmark (\(canRead(file) ? "readable" : "still not readable"))")
        }
    }

    /// Asks the user to pick the file in an Open panel that shows its folder and enables no
    /// other file. Calls `completion` with whether Chest can read it afterwards.
    static func choose(_ file: ProtectedFile, completion: ((Bool) -> Void)? = nil) {
        let panel = NSOpenPanel()
        let delegate = OnlyThisFile(file.url)
        panel.delegate = delegate
        panel.directoryURL = file.url
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.message = "Choose \(file.url.lastPathComponent) to let Chest use it. The panel opens on its folder; select the file and click Allow."
        panel.prompt = "Allow"
        NSApp.activate()
        panel.begin { response in
            // The delegate is held until the panel is done with it.
            withExtendedLifetime(delegate) {}
            guard response == .OK, let url = panel.url else {
                completion?(canRead(file))
                return
            }
            save(url, for: file)
            log("\(file.title): picked, \(canRead(file) ? "readable" : "still not readable")")
            // Unlike Full Disk Access, this takes effect at once, without reopening Chest.
            if canRead(file) { NotificationCenter.default.post(name: .protectedFileGranted, object: file) }
            completion?(canRead(file))
        }
    }

    private static func save(_ url: URL, for file: ProtectedFile) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: file.bookmarkKey)
    }
}

/// Enables only the one file in an Open panel, and the folders on the way to it.
private final class OnlyThisFile: NSObject, NSOpenSavePanelDelegate {
    private let path: String

    init(_ url: URL) {
        path = url.standardizedFileURL.path
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        return candidate == path || path.hasPrefix(candidate + "/")
    }
}
