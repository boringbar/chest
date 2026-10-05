import AppKit
import ChestCore
import ServiceManagement

/// The dot in the menu bar and everything it does.
///
/// - ⌘-drag a menu bar item and a chest hangs under the dot. Drop the item on it and it goes
///   into the drawer: its app is switched off in System Settings › Menu Bar › Allow in the
///   Menu Bar. Leave the item anywhere left of the dot and it is hidden there instead.
/// - Click the dot to open the chest: the items hidden left of it come back, and the drawer
///   opens under it. Click a drawer item and its menu opens right there, while the item
///   stays out of the menu bar. Drag a drawer item to the menu bar to put it back.
/// - Quitting Chest puts every item back in the menu bar; the next launch hides them again.
@MainActor
final class ChestController {
    /// Asks the app to show the welcome window, which explains the permissions.
    var onNeedsPermissions: (() -> Void)?

    private let updater = Updater()

    private enum DotStyle { case dot, open, box }

    /// A ⌘-drag that started in a menu bar.
    private struct Drag {
        let id = UUID()
        /// The dragged item's app, once read; nil while reading or when it is not an app item.
        var bundleID: String?
        var isRead = false
        /// Set when the drag ended before the read finished.
        var isReleased = false
    }

    /// The menu bar while a drawer item is dragged out: the dot's menu bar and the items in it,
    /// left to right, in Cocoa coordinates.
    private struct BarLayout {
        let bar: CGRect
        let items: [(bundleID: String, frame: CGRect)]
    }

    /// An item brought back from the drawer to open, for an app that does not expose its item
    /// while it is switched off.
    private struct OpenedItem {
        let bundleID: String
        let pid: pid_t?
        /// It showed a menu or a window since it opened.
        var sawUI = false
        /// A click outside asked for it to go back once its menu closes.
        var isDismissRequested = false
    }

    private static let spotlight = "com.apple.campo"

    private let store = ChestStore()
    private let statusItem: NSStatusItem
    private let drawer = DrawerPanel()
    private let dropPanel = DropPanel()
    private let marker = InsertionMarker()
    private let notice = NoticePanel()
    /// The chest is open: the hidden items are in the menu bar and the drawer may be showing.
    private var isOpen = false
    private var openMonitors: [Any] = []
    /// Waits for the menus of hidden items to close before hiding them again.
    private var hideTimer: Timer?
    private var dragMonitors: [Any] = []
    private var drag: Drag?
    private var barLayout: BarLayout?
    private var isReadingBarLayout = false
    private var dotStyle = DotStyle.dot
    private var lidWork: DispatchWorkItem?
    private var opened: OpenedItem?
    private var openedTimer: Timer?
    private var openedMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastAgentRestart: Date?
    private let ownBundleID = Bundle.main.bundleIdentifier
    private static let dotAutosaveName = "app.boringbar.chest.dot"
    /// The dot's key among MenuBarAgent's positions. It names an app by its bundle identifier,
    /// and a program outside a bundle (`swift run`) by its process name.
    private var dotPositionKey: String {
        let owner = Bundle.main.bundleURL.pathExtension == "app" ? ownBundleID : nil
        return "status:\(owner ?? ProcessInfo.processInfo.processName)::\(Self.dotAutosaveName)"
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Keeps the dot where the user ⌘-dragged it, across launches.
        statusItem.autosaveName = Self.dotAutosaveName
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(dotClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Chest")
        }
        applyDotStyle(.dot)

        drawer.onOpen = { [weak self] bundleID in self?.open(bundleID) }
        drawer.onRemove = { [weak self] bundleID in self?.remove(bundleID) }
        drawer.onDragMove = { [weak self] bundleID, point in self?.dragOutMoved(bundleID, to: point) ?? false }
        drawer.onDragEnd = { [weak self] bundleID, point in self?.dragOutEnded(bundleID, at: point) }
        store.onChange = { [weak self] in self?.refreshDrawer() }

        installDragMonitors()
        observeWorkspace()
        hideChestItems()
    }

    /// Puts every item back in the menu bar. Called when Chest quits.
    func restoreAll() {
        endOpened(rehide: false)
        MenuBarSwitches.set(true, for: store.all)
    }

    // MARK: - The dot

    @objc private func dotClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        if isOpen {
            closeChest()
            return
        }
        guard Permissions.allGranted else {
            onNeedsPermissions?()
            return
        }
        openChest()
    }

    private func applyDotStyle(_ style: DotStyle) {
        dotStyle = style
        guard let button = statusItem.button else { return }
        let image: NSImage?
        switch style {
        case .dot:
            image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Chest")?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        case .open:
            // The dot as a ring, the same size, while the chest is open. macOS 27 draws status items in MenuBarAgent,
            // which ignores the button's highlight.
            image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Chest, open")?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        case .box:
            // An open chest to drop into.
            image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Drop into Chest")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        image?.isTemplate = true
        button.image = image
        button.toolTip = store.all.isEmpty
            ? "Chest: ⌘-drag a menu bar item left of the dot to hide it, or onto the chest that appears to keep it in the drawer"
            : "Chest: click to open"
    }

    /// The dot's look when nothing is being dragged.
    private var restingStyle: DotStyle { isOpen ? .open : .dot }

    /// The box closes over a new item: shows the box for a moment, then the dot again.
    private func closeLid() {
        lidWork?.cancel()
        applyDotStyle(.box)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag == nil else { return }
            self.applyDotStyle(self.restingStyle)
        }
        lidWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The dot's frame (Cocoa coordinates) and screen.
    private var dot: (frame: CGRect, screen: NSScreen)? {
        guard let window = statusItem.button?.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.frame, screen)
    }

    /// The menu bar the dot is in.
    private var dotMenuBar: CGRect? {
        guard let dot else { return nil }
        return Screens.menuBars.first { $0.intersects(dot.frame) }
    }

    /// The lines under the version in About Chest. The license line is here rather than in
    /// `NSHumanReadableCopyright`, which About shows as plain text, so it can link.
    private static var aboutCredits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: "A project by boringBar\n", attributes: attributes)
        var link = attributes
        link[.link] = URL(string: "https://boringbar.app")!
        credits.append(NSAttributedString(string: "https://boringbar.app\n", attributes: link))
        let spaced = NSMutableParagraphStyle()
        spaced.alignment = .center
        spaced.paragraphSpacingBefore = 6
        var license = attributes
        license[.paragraphStyle] = spaced
        credits.append(NSAttributedString(string: "Open source under the MIT License\n", attributes: license))
        credits.append(NSAttributedString(string: "https://github.com/boringbar/chest", attributes: link))
        return credits
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: isOpen ? "Close Chest" : "Open Chest") { [weak self] in
            self?.dotClicked()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Permissions") { [weak self] in self?.onNeedsPermissions?() })
        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = ClosureMenuItem(title: "Open at Login") {
                let service = SMAppService.mainApp
                try? service.status == .enabled ? service.unregister() : service.register()
            }
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        if updater.isAvailable {
            let check = ClosureMenuItem(title: "Check for Updates") { [weak self] in self?.updater.checkForUpdates() }
            check.isEnabled = updater.canCheckForUpdates
            menu.addItem(check)
        }
        menu.addItem(ClosureMenuItem(title: "About Chest") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Chest", keyEquivalent: "q") { NSApp.terminate(nil) })
        closeDrawer()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // A lasting menu would take every left click as well.
        statusItem.menu = nil
    }

    // MARK: - Putting items in and taking them out

    private func hideChestItems() {
        // While the chest is open the hidden items stay out.
        let items = isOpen ? Set(store.items) : store.all
        guard !items.isEmpty else { return }
        if switchOff(items) == .noAccess {
            onNeedsPermissions?()
        }
    }

    /// Puts an app's items in the drawer or hides them left of the dot. Hidden items stay in
    /// the menu bar while the chest is open, as the others there do.
    private func put(_ bundleID: String, in section: Section) {
        let name = AppInfo(bundleID: bundleID).name
        let result: MenuBarSwitches.Result
        if section == .drawer || !isOpen {
            result = switchOff([bundleID])
        } else if MenuBarSwitches.isListed(bundleID) {
            result = .done
        } else {
            result = MenuBarSwitches.hasAccess ? .untracked([bundleID]) : .noAccess
        }
        switch result {
        case .done:
            store.add(bundleID, to: section)
            if section == .drawer || !isOpen { closeLid() }
        case .untracked:
            applyDotStyle(restingStyle)
            showNotice("Chest can’t hide \(name) yet",
                       detail: "macOS hasn’t listed \(name) under System Settings › Menu Bar › Allow in the Menu Bar, so its item can’t be switched off. This happens most with apps outside the Applications folder. Refreshing the menu bar makes macOS list every app with an item; the menu bar blinks once.",
                       action: ("Refresh Menu Bar", { [weak self] in self?.refreshMenuBar(thenPut: bundleID, in: section) }))
        case .noAccess:
            applyDotStyle(restingStyle)
            showNotice("Chest needs Full Disk Access",
                       detail: "It hides items through macOS’s own “Allow in the Menu Bar” switches, which are kept in a protected place.",
                       action: ("Open Settings", Permissions.openFullDiskAccess))
        }
    }

    /// Switches items off, then checks that they left the menu bar. MenuBarAgent can stop
    /// noticing changes to the list while it runs, leaving every item where it is (seen once,
    /// with about 70 apps; the trigger is not known). Restarting it makes it read the list
    /// again, as Refresh Menu Bar does.
    @discardableResult
    private func switchOff(_ bundleIDs: Set<String>) -> MenuBarSwitches.Result {
        let result = MenuBarSwitches.set(false, for: bundleIDs)
        if result == .done { confirmGone(bundleIDs) }
        return result
    }

    private func confirmGone(_ bundleIDs: Set<String>) {
        Task { [weak self] in
            // MenuBarAgent takes well under a second to apply a change.
            try? await Task.sleep(for: .seconds(1.5))
            let shown = await Task.detached { MenuBarItems.shownBundleIDs() }.value
            guard let self else { return }
            // Only those that should still be away: the chest may have opened meanwhile.
            let stuck = bundleIDs.intersection(shown).filter(self.shouldBeHidden)
            guard !stuck.isEmpty else { return }
            // A restart that did not help would not help again right away.
            if let last = self.lastAgentRestart, Date().timeIntervalSince(last) < 30 {
                log("MenuBarAgent still shows \(stuck.sorted()) after a restart")
                return
            }
            log("MenuBarAgent kept \(stuck.sorted()) after switching them off; restarting it")
            self.restartMenuBarAgent()
        }
    }

    /// Whether an app's items should be out of the menu bar right now.
    private func shouldBeHidden(_ bundleID: String) -> Bool {
        switch store.section(of: bundleID) {
        case .drawer: opened?.bundleID != bundleID
        case .hidden: !isOpen
        case nil: false
        }
    }

    /// Restarts MenuBarAgent, which reads the list and lists every running app with an item
    /// as it starts. launchd starts it again at once; the menu bar blinks once.
    private func restartMenuBarAgent() {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
        lastAgentRestart = Date()
        kill(agent.processIdentifier, SIGTERM)
    }

    /// Restarts MenuBarAgent so it lists `bundleID`, then tries it again.
    private func refreshMenuBar(thenPut bundleID: String, in section: Section) {
        log("restarting MenuBarAgent to list \(bundleID)")
        restartMenuBarAgent()
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(300))
                if MenuBarSwitches.isListed(bundleID) { break }
            }
            self?.put(bundleID, in: section)
        }
    }

    private func remove(_ bundleID: String) {
        if opened?.bundleID == bundleID { endOpened(rehide: false) }
        store.remove(bundleID)
        MenuBarSwitches.set(true, for: [bundleID])
    }

    // MARK: - ⌘-dragging menu bar items

    private func installDragMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let flags = event.modifierFlags
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleDrag(type, flags: flags, at: location) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: handler) {
            dragMonitors.append(monitor)
        }
    }

    private func handleDrag(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, at location: CGPoint) {
        switch type {
        case .leftMouseDown:
            drag = nil
            guard flags.contains(.command), Screens.menuBars.contains(where: { $0.contains(location) }) else { return }
            let current = Drag()
            drag = current
            readDraggedItem(at: location, dragID: current.id)
        case .leftMouseDragged:
            guard let drag, drag.bundleID != nil, let dot else { return }
            if !dropPanel.isVisible {
                // The drawer would be in the way of the chest.
                closeDrawer()
                dropPanel.show(under: dot.frame, on: dot.screen)
            }
            dropPanel.isTargeted = dropPanel.frame.contains(location)
            let style: DotStyle = dropPanel.isTargeted ? .box : restingStyle
            if style != dotStyle { applyDotStyle(style) }
        case .leftMouseUp:
            guard var current = drag else { return }
            let onChest = dropPanel.isVisible && dropPanel.frame.contains(location)
            dropPanel.dismiss()
            if !current.isRead {
                // The item is not known yet; settle it once the read lands. The chest showed
                // only once it was known, so it was not dropped there.
                current.isReleased = true
                drag = current
                return
            }
            drag = nil
            finishDrop(of: current.bundleID, onChest: onChest)
        default:
            break
        }
    }

    private func readDraggedItem(at location: CGPoint, dragID: UUID) {
        let point = Screens.flipped(CGRect(origin: location, size: .zero)).origin
        let own = ownBundleID
        let away = Set(store.all.filter(shouldBeHidden))
        Task.detached(priority: .userInitiated) {
            let hit = MenuBarItems.items(inMenuBarContaining: point)
                .first { $0.frame.minX <= point.x && point.x < $0.frame.maxX }
            var bundleID = hit.map(\.bundleID).flatMap { $0 == own ? nil : $0 }
            // An item that was just switched off can still be listed where the next one slides
            // in. The drag's own window shows which item it really is, once it is up.
            if let read = bundleID, away.contains(read) {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(60))
                    if let dragged = MenuBarItems.draggedItem() {
                        bundleID = dragged == own ? nil : dragged
                        break
                    }
                }
                log("\(read) was already away; the drag is on \(bundleID ?? "nothing")")
            }
            await MainActor.run { [weak self] in
                guard let self, var current = self.drag, current.id == dragID else { return }
                current.bundleID = bundleID
                current.isRead = true
                log("drag started on \(bundleID ?? "nothing")")
                if current.isReleased {
                    self.drag = nil
                    self.finishDrop(of: bundleID, onChest: false)
                } else {
                    self.drag = current
                }
            }
        }
    }

    /// Dropped on the chest, the item goes into the drawer. Anywhere else MenuBarAgent puts it
    /// in the menu bar where it was let go: left of the dot it is hidden, right of it shown.
    private func finishDrop(of bundleID: String?, onChest: Bool) {
        if dotStyle != restingStyle { applyDotStyle(restingStyle) }
        guard let bundleID else { return }
        if onChest {
            log("dropped \(bundleID) into the chest")
            // Let MenuBarAgent finish settling the drop before the item disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.put(bundleID, in: .drawer) }
            return
        }
        // MenuBarAgent moves the item into place over a few frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.settle(bundleID) }
    }

    /// Hides an item left where it was let go left of the dot, and shows a hidden one moved
    /// right of it.
    private func settle(_ bundleID: String) {
        guard store.section(of: bundleID) != .drawer, let dot, let bar = dotMenuBar else { return }
        Task { [weak self] in
            guard let found = await Task.detached(operation: { MenuBarItems.frame(of: bundleID) }).value, let self else { return }
            let frame = Screens.flipped(found)
            guard bar.intersects(frame) else { return }
            if frame.midX < dot.frame.midX {
                guard self.store.section(of: bundleID) != .hidden else { return }
                log("\(bundleID) left of the dot: hiding it")
                self.put(bundleID, in: .hidden)
            } else if self.store.section(of: bundleID) == .hidden {
                log("\(bundleID) right of the dot: showing it")
                self.store.remove(bundleID)
            }
        }
    }

    // MARK: - Dragging items out of the drawer

    /// Shows where a drawer item dragged to `point` would go. Returns whether it can be
    /// dropped there: anywhere in the dot's menu bar.
    private func dragOutMoved(_ bundleID: String, to point: CGPoint) -> Bool {
        if barLayout == nil {
            readBarLayout(without: bundleID)
            return false
        }
        guard let target = dropTarget(at: point) else {
            marker.dismiss()
            return false
        }
        marker.show(at: target.x, in: target.bar)
        return true
    }

    private func dragOutEnded(_ bundleID: String, at point: CGPoint) {
        marker.dismiss()
        defer { barLayout = nil }
        guard let target = dropTarget(at: point), let layout = barLayout else { return }
        // Its place among the others, between the positions MenuBarAgent keeps for them.
        // Items it keeps no position for (its own modules) are skipped.
        let positions = MenuBarPositions.all()
        let own = ownBundleID ?? ""
        let known = layout.items.map {
            $0.bundleID == own ? positions[dotPositionKey] : PreferredPositions.position(of: $0.bundleID, in: positions)
        }
        let left = known[..<target.index].last { $0 != nil } ?? nil
        let right = known[target.index...].first { $0 != nil } ?? nil
        if let position = PreferredPositions.between(left, and: right) {
            MenuBarPositions.set(position, for: bundleID)
        }
        log("dragged \(bundleID) out of the drawer, \(target.isLeftOfDot ? "left" : "right") of the dot")
        if target.isLeftOfDot {
            store.add(bundleID, to: .hidden)
            if isOpen { MenuBarSwitches.set(true, for: [bundleID]) }
        } else {
            store.remove(bundleID)
            MenuBarSwitches.set(true, for: [bundleID])
        }
    }

    /// Reads the items in the dot's menu bar, once per drag out.
    private func readBarLayout(without bundleID: String) {
        guard !isReadingBarLayout, let dot, let bar = dotMenuBar else { return }
        isReadingBarLayout = true
        let point = Screens.flipped(CGRect(x: bar.midX, y: bar.midY, width: 0, height: 0)).origin
        let own = ownBundleID ?? ""
        Task { [weak self] in
            let items = await Task.detached { MenuBarItems.items(inMenuBarContaining: point) }.value
            guard let self else { return }
            self.isReadingBarLayout = false
            var layout = items
                .filter { $0.bundleID != bundleID && $0.bundleID != own }
                .map { (bundleID: $0.bundleID, frame: Screens.flipped($0.frame)) }
            // A build run from the terminal has no bundle in the window list; add the dot itself.
            layout.append((bundleID: own, frame: dot.frame))
            self.barLayout = BarLayout(bar: bar, items: layout.sorted { $0.frame.minX < $1.frame.minX })
        }
    }

    /// Where a drawer item let go at `point` goes: at `x`, before the item at `index`.
    private func dropTarget(at point: CGPoint) -> (x: CGFloat, bar: CGRect, index: Int, isLeftOfDot: Bool)? {
        guard let layout = barLayout,
              point.y >= layout.bar.minY - 6, point.y <= layout.bar.maxY + 1,
              point.x >= layout.bar.minX, point.x <= layout.bar.maxX else { return nil }
        let frames = layout.items.map(\.frame)
        let index = MenuBarGeometry.insertionIndex(at: point.x, among: frames)
        let x = index < frames.count ? frames[index].minX : (frames.last?.maxX ?? point.x)
        let dotIndex = layout.items.firstIndex { $0.bundleID == (ownBundleID ?? "") } ?? frames.count
        return (x, layout.bar, index, index <= dotIndex)
    }

    // MARK: - Opening and closing the chest

    private var drawerItems: [AppInfo] {
        // An app that is not running has no item to show.
        store.items.map(AppInfo.init).filter(\.isRunning)
    }

    /// Shows the hidden items left of the dot and opens the drawer under it.
    private func openChest() {
        endOpened(rehide: true)
        notice.dismiss()
        guard let dot else { return }
        isOpen = true
        hideTimer?.invalidate()
        hideTimer = nil
        if !store.hidden.isEmpty {
            MenuBarSwitches.set(true, for: Set(store.hidden))
        }
        // With nothing in the drawer but items hidden, those are all there is to show. With
        // nothing at all, the drawer says how to put something in.
        if !drawerItems.isEmpty || store.hidden.isEmpty {
            drawer.show(items: drawerItems, under: dot.frame, on: dot.screen)
        }
        applyDotStyle(.open)

        let click: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.openClick(at: location) }
        }
        let key: (NSEvent) -> Void = { [weak self] event in
            let isEscape = event.keyCode == 53
            MainActor.assumeIsolated { if isEscape { self?.closeChest() } }
        }
        openMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: click),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { click($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let isEscape = event.keyCode == 53
                key(event)
                return isEscape ? nil : event
            },
        ].compactMap { $0 }
    }

    /// A click while the chest is open. Clicks in the menu bar, and in what its items open,
    /// keep the hidden items out so they can be used; anywhere else the chest closes.
    private func openClick(at location: CGPoint) {
        guard isOpen else { return }
        // The dot toggles the chest itself; clicks in the drawer belong to it.
        if drawer.isVisible && drawer.frame.contains(location) || dot?.frame.contains(location) == true { return }
        if Screens.menuBars.contains(where: { $0.contains(location) }) {
            // An item there opens its menu where the drawer may be.
            closeDrawer()
            return
        }
        let pids = Set(store.hidden.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier })
        let inHiddenAppWindow = Screens.windows().contains { pids.contains($0.pid) && $0.level > 0 && $0.frame.contains(location) }
        guard !inHiddenAppWindow,
              MenuBarGeometry.isOutside(location, menuBars: Screens.menuBars, menus: Screens.openMenus) else { return }
        closeChest()
    }

    /// Closes the drawer and hides the hidden items again, once whatever they opened has
    /// closed (hiding an item pulls it out from under its menu), or at once with `immediately`.
    private func closeChest(animated: Bool = true, immediately: Bool = false) {
        openMonitors.forEach(NSEvent.removeMonitor)
        openMonitors.removeAll()
        closeDrawer(animated: animated)
        let wasOpen = isOpen
        isOpen = false
        if dotStyle == .open { applyDotStyle(.dot) }
        guard wasOpen else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        let hidden = Set(store.hidden)
        guard !hidden.isEmpty else { return }
        if immediately || !isHiddenItemShowingUI() {
            switchOff(hidden)
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideWhenUnused() }
        }
    }

    private func hideWhenUnused() {
        guard !isOpen, !isHiddenItemShowingUI() else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        switchOff(Set(store.hidden))
    }

    /// Whether a menu hangs from the menu bar, or an app hidden left of the dot shows a
    /// window above normal ones (a popover or panel).
    private func isHiddenItemShowingUI() -> Bool {
        if !MenuBarGeometry.menuBarMenus(Screens.openMenus, menuBars: Screens.menuBars).isEmpty { return true }
        let pids = Set(store.hidden.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier })
        return Screens.windows().contains { pids.contains($0.pid) && $0.level > 0 }
    }

    /// Closes only the drawer; the chest stays open.
    private func closeDrawer(animated: Bool = true) {
        drawer.dismiss(animated: animated)
    }

    private func refreshDrawer() {
        applyDotStyle(dotStyle)
        guard drawer.isVisible, let dot else { return }
        if drawerItems.isEmpty && !store.hidden.isEmpty {
            closeDrawer()
            return
        }
        drawer.update(items: drawerItems, under: dot.frame, on: dot.screen)
    }

    // MARK: - Opening an item from the drawer

    /// Opens a drawer item without bringing it back to the menu bar. Its app keeps the status
    /// item while it is switched off: a menu is read and shown under the drawer icon, and
    /// what is chosen there is pressed in the real one; anything else (a popover, a window)
    /// is opened by pressing the item where it was last drawn.
    private func open(_ bundleID: String) {
        endOpened(rehide: true)
        if bundleID == Self.spotlight {
            // Spotlight's item is gone while switched off, but its shortcut still works.
            closeChest()
            openSpotlight()
            return
        }
        Task { [weak self] in
            let extra = await Task.detached { MenuBarItems.appExtra(of: bundleID) }.value
            guard let self else { return }
            guard let extra else {
                log("\(bundleID) has no item while hidden; opening it in the menu bar")
                self.closeChest()
                self.openInMenuBar(bundleID)
                return
            }
            let entries = await Task.detached { MenuBarItems.menu(of: extra) }.value
            if let entries, !entries.isEmpty {
                guard self.drawer.isVisible else { return }
                self.drawer.popUp(self.makeMenu(entries), under: bundleID)
            } else {
                self.closeChest()
                await Task.detached { MenuBarItems.press(extra) }.value
            }
        }
    }

    /// A copy of an item's menu. Choosing an entry presses the real one.
    private func makeMenu(_ entries: [MenuBarItems.MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = ClosureMenuItem(title: entry.title) { [weak self] in
                self?.closeChest()
                Task.detached { MenuBarItems.press(entry.element) }
            }
            item.isEnabled = entry.isEnabled
            item.state = entry.mark == nil ? .off : entry.mark == "-" ? .mixed : .on
            if let key = entry.keyEquivalent {
                // Shown only; the menu is not there when the key is pressed.
                item.keyEquivalent = key.lowercased()
                var mask: NSEvent.ModifierFlags = entry.modifiers & 8 == 0 ? [.command] : []
                // Accessibility gives letters in capitals either way; Shift is its own flag.
                if entry.modifiers & 1 != 0 { mask.insert(.shift) }
                if entry.modifiers & 2 != 0 { mask.insert(.option) }
                if entry.modifiers & 4 != 0 { mask.insert(.control) }
                item.keyEquivalentModifierMask = mask
            }
            if let submenu = entry.submenu {
                item.submenu = makeMenu(submenu)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Opens Spotlight with its keyboard shortcut (System Settings › Keyboard › Keyboard
    /// Shortcuts › Spotlight), ⌘-Space unless it was changed.
    private func openSpotlight() {
        var keyCode: CGKeyCode = 49
        var flags = CGEventFlags.maskCommand
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        if let entry = hotKeys?["64"] as? [String: Any] {
            guard (entry["enabled"] as? Bool) ?? true else {
                showNotice("Couldn’t open Spotlight", detail: "Its keyboard shortcut is switched off in System Settings › Keyboard › Keyboard Shortcuts › Spotlight.")
                return
            }
            if let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 {
                keyCode = CGKeyCode(parameters[1])
                flags = CGEventFlags(rawValue: UInt64(parameters[2]))
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Brings the item back to the menu bar just long enough to open it, for an app that
    /// exposes no item while it is switched off.
    private func openInMenuBar(_ bundleID: String) {
        let name = AppInfo(bundleID: bundleID).name
        guard MenuBarSwitches.set(true, for: [bundleID]) == .done else {
            showNotice("Couldn’t open \(name)", detail: "Its menu bar item could not be switched back on.")
            return
        }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        opened = OpenedItem(bundleID: bundleID, pid: pid)
        Task { [weak self] in
            // MenuBarAgent draws the item again within a few frames.
            var element: MenuBarItems.Element?
            for _ in 0..<50 {
                element = await Task.detached { MenuBarItems.menuExtra(of: bundleID) }.value
                if element != nil { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let self, self.opened?.bundleID == bundleID else { return }
            guard let element else {
                self.endOpened(rehide: true)
                self.showNotice("Couldn’t open \(name)", detail: "Its item didn’t come back to the menu bar. There may not be room for it.")
                return
            }
            await Task.detached { MenuBarItems.press(element) }.value
            // Most items open on a press; a few take only a real click.
            try? await Task.sleep(for: .milliseconds(350))
            guard self.opened?.bundleID == bundleID else { return }
            if !self.isOpenedItemShowingUI() {
                log("\(bundleID) ignored the press; clicking it")
                await self.click(bundleID)
            }
            self.watchOpened()
        }
    }

    /// Clicks the item where it is drawn and puts the pointer back where it was.
    private func click(_ bundleID: String) async {
        guard let frame = await Task.detached(operation: { MenuBarItems.frame(of: bundleID) }).value else { return }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let saved = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    /// Whether the opened item shows something: a menu hanging from the menu bar, or a
    /// window of its app above normal windows (a popover or panel).
    private func isOpenedItemShowingUI() -> Bool {
        if !MenuBarGeometry.menuBarMenus(Screens.openMenus, menuBars: Screens.menuBars).isEmpty { return true }
        guard let pid = opened?.pid else { return false }
        return Screens.windows().contains { $0.pid == pid && $0.level > 0 }
    }

    /// Puts the opened item back once what it opened has closed, or after a click outside
    /// the menu bar, its menu and its app's windows.
    private func watchOpened() {
        let pid = opened?.pid
        openedTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOpened() }
        }
        let click: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, var current = self.opened else { return }
                let inAppWindow = Screens.windows().contains { $0.pid == pid && $0.frame.contains(location) }
                guard !inAppWindow,
                      MenuBarGeometry.isOutside(location, menuBars: Screens.menuBars, menus: Screens.openMenus) else { return }
                current.isDismissRequested = true
                self.opened = current
                self.checkOpened()
            }
        }
        openedMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { click($0); return $0 },
        ].compactMap { $0 }
    }

    private func checkOpened() {
        guard var current = opened else { return }
        if isOpenedItemShowingUI() {
            current.sawUI = true
            opened = current
        } else if current.sawUI || current.isDismissRequested {
            // Hiding while its menu is open would pull the item out from under the menu.
            endOpened(rehide: true)
        }
    }

    private func endOpened(rehide: Bool) {
        openedTimer?.invalidate()
        openedTimer = nil
        openedMonitors.forEach(NSEvent.removeMonitor)
        openedMonitors.removeAll()
        guard let current = opened else { return }
        opened = nil
        if rehide, store.contains(current.bundleID), !(isOpen && store.section(of: current.bundleID) == .hidden) {
            switchOff([current.bundleID])
        }
    }

    // MARK: - Notices

    private func showNotice(_ title: String, detail: String, action: (String, () -> Void)? = nil) {
        guard let dot else { return }
        notice.show(title: title, detail: detail, action: action, under: dot.frame, on: dot.screen)
    }

    // MARK: - Workspace

    /// Closes the chest and any notice, puts an opened item back and forgets a drag.
    private func putEverythingAway(reason: String) {
        log("putting everything away: \(reason)")
        drag = nil
        barLayout = nil
        dropPanel.dismiss()
        marker.dismiss()
        lidWork?.cancel()
        notice.dismiss(animated: false)
        closeChest(animated: false, immediately: true)
        endOpened(rehide: true)
        applyDotStyle(.dot)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeChest() }
            },
            // Nothing should wait across sleep or a locked screen: a drawer left hanging, or
            // hidden items left in the menu bar.
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.putEverythingAway(reason: "sleep") }
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.putEverythingAway(reason: "screens sleep") }
            },
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.putEverythingAway(reason: "session resigned") }
            },
            // The switches persist, but check them on wake in case something switched an item
            // back on meanwhile (System Settings, a MenuBarAgent restart).
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideChestItems() }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideChestItems() }
            },
            // Apps come and go from the drawer as they launch and quit.
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrawer() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrawer() }
            },
        ]
    }
}
