import AppKit
import ApplicationServices

/// The items macOS 27 shows in the menu bar, read and pressed over Accessibility.
///
/// MenuBarAgent draws every item into one window per menu bar (and keeps one per Space).
/// Each child of such a window is a slot carrying the item's frame. An app item's slot holds
/// an `AXApplication` element owned by the app; under it, the app's extras menu bar holds the
/// item itself, an `AXMenuBarItem` with the `AXMenuExtra` subrole that takes `AXPress`.
/// Only MenuBarAgent and that one element are asked anything, so an unresponsive app cannot
/// stall a read. Every call is a blocking IPC: call off the main thread.
enum MenuBarItems {
    /// An `AXUIElement` that may cross threads. It is only a token for an IPC endpoint.
    struct Element: @unchecked Sendable {
        let raw: AXUIElement
    }

    struct Item: Sendable {
        let bundleID: String
        /// Accessibility coordinates: origin at the top left of the primary display.
        let frame: CGRect
    }

    /// App items in the menu bar that contains `point` (Accessibility coordinates).
    static func items(inMenuBarContaining point: CGPoint) -> [Item] {
        var items: [String: Item] = [:]
        forEachSlot { window, slotFrame, bundleID, _ in
            guard window.contains(point) else { return }
            // The same item shows in every Space's window; keep one.
            if items[bundleID] == nil { items[bundleID] = Item(bundleID: bundleID, frame: slotFrame) }
        }
        return items.values.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The item being ⌘-dragged. While a drag lasts, MenuBarAgent draws the item in a small
    /// window of its own that rises above the top of the screen.
    static func draggedItem() -> String? {
        var found: String?
        forEachSlot { window, _, bundleID, _ in
            if found == nil, window.minY < 0 { found = bundleID }
        }
        return found
    }

    /// Where the item of `bundleID` is drawn, on any display.
    static func frame(of bundleID: String) -> CGRect? {
        var found: CGRect?
        forEachSlot { _, slot, owner, _ in
            if found == nil, owner == bundleID { found = slot }
        }
        return found
    }

    /// The apps with an item drawn in a menu bar right now, in one pass.
    static func shownBundleIDs() -> Set<String> {
        var found: Set<String> = []
        forEachSlot { _, _, bundleID, _ in found.insert(bundleID) }
        return found
    }

    /// The pressable item of `bundleID`, if it is in the menu bar right now.
    static func menuExtra(of bundleID: String) -> Element? {
        var found: Element?
        forEachSlot { _, _, owner, element in
            guard found == nil, owner == bundleID else { return }
            for bar in children(of: element) {
                for item in children(of: bar) where string(item, kAXSubroleAttribute) == "AXMenuExtra" {
                    found = Element(raw: item)
                    return
                }
            }
        }
        return found
    }

    /// The item of `bundleID` as its app exposes it. Unlike `menuExtra(of:)` this does not
    /// go through MenuBarAgent, so it is there while the item is switched off: the app keeps
    /// its status item, with its menu, and pressing it opens that menu or popover where the
    /// item was last drawn.
    static func appExtra(of bundleID: String) -> Element? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let extra = children(of: bar as! AXUIElement).first { string($0, kAXSubroleAttribute) == "AXMenuExtra" }
        return extra.map(Element.init)
    }

    /// An entry of an item's menu, read over Accessibility.
    struct MenuEntry: Sendable {
        let title: String
        let isEnabled: Bool
        let mark: String?
        let keyEquivalent: String?
        /// `AXMenuItemCmdModifiers`: 1 Shift, 2 Option, 4 Control, 8 no Command.
        let modifiers: Int
        let element: Element
        /// Its submenu, if it has one.
        let submenu: [MenuEntry]?

        var isSeparator: Bool { title.isEmpty && submenu == nil && keyEquivalent == nil }
    }

    /// The menu of an item, or nil when it has none (it shows a popover or a window instead).
    /// Reading it makes the app update it, as it would before opening it.
    static func menu(of extra: Element) -> [MenuEntry]? {
        AXUIElementSetMessagingTimeout(extra.raw, 1)
        guard let menu = children(of: extra.raw).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else { return nil }
        return entries(of: menu, depth: 0)
    }

    private static func entries(of menu: AXUIElement, depth: Int) -> [MenuEntry] {
        children(of: menu).compactMap { item in
            guard string(item, kAXRoleAttribute) == kAXMenuItemRole else { return nil }
            let submenu = depth < 4
                ? children(of: item).first { string($0, kAXRoleAttribute) == kAXMenuRole }.map { entries(of: $0, depth: depth + 1) }
                : nil
            var enabled: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
            var modifiers: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
            return MenuEntry(
                title: string(item, kAXTitleAttribute) ?? "",
                isEnabled: (enabled as? Bool) ?? true,
                mark: string(item, kAXMenuItemMarkCharAttribute).flatMap { $0.isEmpty ? nil : $0 },
                keyEquivalent: string(item, kAXMenuItemCmdCharAttribute).flatMap { $0.isEmpty ? nil : $0 },
                modifiers: (modifiers as? Int) ?? 0,
                element: Element(raw: item),
                submenu: submenu
            )
        }
    }

    /// Presses an item as a click would. Opening a menu keeps the call waiting until the menu
    /// closes, so the timeout is short and its error means nothing.
    static func press(_ element: Element) {
        AXUIElementSetMessagingTimeout(element.raw, 0.25)
        _ = AXUIElementPerformAction(element.raw, kAXPressAction as CFString)
    }

    // MARK: - Tree walking

    private static func forEachSlot(_ body: (_ window: CGRect, _ slot: CGRect, _ bundleID: String, _ owner: AXUIElement) -> Void) {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        for window in elements(app, kAXWindowsAttribute) {
            guard let windowFrame = frame(of: window) else { continue }
            for slot in children(of: window) {
                guard let slotFrame = frame(of: slot), slotFrame.width > 0,
                      let owner = children(of: slot).first else { continue }
                var pid: pid_t = 0
                guard AXUIElementGetPid(owner, &pid) == .success, pid != agent.processIdentifier,
                      let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
                body(windowFrame, slotFrame, bundleID, owner)
            }
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Screen helpers

enum Screens {
    /// Height of the primary display, for flipping between Cocoa and Accessibility coordinates.
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// A Cocoa rectangle in Accessibility coordinates, or the other way round.
    @MainActor static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The menu bar of every screen. While the menu bar hides itself, `visibleFrame` reaches
    /// the top of the screen, so the status bar thickness stands in.
    @MainActor static var menuBars: [CGRect] {
        NSScreen.screens.map { screen in
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
        }
    }

    /// Frames of the menus open on screen: other apps' windows at the pop-up menu level (Chest's
    /// own drawer and panels sit there too). Reading the window list needs no permission.
    @MainActor static var openMenus: [CGRect] {
        let own = getpid()
        return windows(atLevel: Int(CGWindowLevelForKey(.popUpMenuWindow))).filter { $0.pid != own }.map(\.frame)
    }

    /// On-screen windows, optionally only those at `level`, with owner and Cocoa frame.
    @MainActor static func windows(atLevel level: Int? = nil) -> [(pid: pid_t, level: Int, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if let level, layer != level { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (pid, layer, flipped(rect))
        }
    }
}
