import AppKit
import ChestCore

/// The drawer that hangs under the dot and holds the items in the chest.
///
/// It never becomes key, so the frontmost app keeps focus, as with a menu. Items take clicks
/// anyway: a click opens the item in place, a right-click offers to take it out, and an item
/// dragged to the menu bar goes back there.
@MainActor
final class DrawerPanel: NSPanel {
    var onOpen: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    /// An item is dragged out to a point on screen; returns whether it can be dropped there.
    var onDragMove: ((String, CGPoint) -> Bool)?
    /// An item dragged out was let go at a point on screen.
    var onDragEnd: ((String, CGPoint) -> Void)?

    private static let cornerRadius: CGFloat = 10
    private static let padding: CGFloat = 5
    private static let itemSize = NSSize(width: 34, height: 28)
    /// Icons per row; more wrap to the next, so a full chest grows down, not off the screen.
    private static let columns = 10

    private let effectView = NSVisualEffectView()
    private let stack = NSStackView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none

        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.maskImage = .roundedMask(radius: Self.cornerRadius)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = effectView

        // Rows of icons, top to bottom.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Chest")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the drawer with `items` under `dot` (Cocoa coordinates) on `screen`.
    func show(items: [AppInfo], under dot: CGRect, on screen: NSScreen) {
        rebuild(items)
        let size = stack.fittingSize
        let origin = MenuBarGeometry.drawerOrigin(size: size, under: dot, in: screen.frame)
        let frame = NSRect(origin: origin, size: size)
        if isVisible {
            setFrame(frame, display: true, animate: false)
            return
        }
        // Slides down a few points as it fades in, like a menu settling into place.
        setFrame(frame.offsetBy(dx: 0, dy: 6), display: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
        }
    }

    /// Updates the items of an open drawer, keeping it under the dot.
    func update(items: [AppInfo], under dot: CGRect, on screen: NSScreen) {
        guard isVisible else { return }
        show(items: items, under: dot, on: screen)
    }

    /// Fades out, or with `animated: false` goes at once (before sleep, when an animation
    /// would only finish on wake).
    func dismiss(animated: Bool = true) {
        guard isVisible else { return }
        guard animated else {
            alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }

    /// Opens `menu` under the item of `bundleID`, as the menu bar would under the item itself.
    /// Returns once the menu closes.
    func popUp(_ menu: NSMenu, under bundleID: String) {
        let views = stack.arrangedSubviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }
        guard let view = views.compactMap({ $0 as? DrawerItemView }).first(where: { $0.bundleID == bundleID }) else { return }
        view.isOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        view.isOpen = false
    }

    private func rebuild(_ items: [AppInfo]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !items.isEmpty else {
            let label = NSTextField(wrappingLabelWithString: "⌘-drag a menu bar item and drop it\non the chest under the dot to keep it here.")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            stack.addArrangedSubview(container)
            return
        }
        var row: NSStackView?
        for (index, info) in items.enumerated() {
            if index % Self.columns == 0 {
                let next = NSStackView()
                next.orientation = .horizontal
                next.spacing = 2
                stack.addArrangedSubview(next)
                row = next
            }
            let view = DrawerItemView(info: info, size: Self.itemSize)
            view.onOpen = { [weak self] in self?.onOpen?(info.bundleID) }
            view.onRemove = { [weak self] in self?.onRemove?(info.bundleID) }
            view.onDragMove = { [weak self] point in self?.onDragMove?(info.bundleID, point) ?? false }
            view.onDragEnd = { [weak self] point in self?.onDragEnd?(info.bundleID, point) }
            row?.addArrangedSubview(view)
        }
    }
}

/// One item in the drawer: the app's icon, highlighted under the pointer like a menu bar item.
@MainActor
private final class DrawerItemView: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDragMove: ((CGPoint) -> Bool)?
    var onDragEnd: ((CGPoint) -> Void)?

    var bundleID: String { info.bundleID }
    /// Its menu is open under it.
    var isOpen = false { didSet { needsDisplay = true } }

    private let info: AppInfo
    private let size: NSSize
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var mouseDownPoint: NSPoint?
    private var isDragging = false { didSet { needsDisplay = true } }
    /// The icon following the pointer while it is dragged out.
    private var dragImage: DragImageWindow?
    private var canDrop = false

    init(info: AppInfo, size: NSSize) {
        self.info = info
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
        toolTip = info.name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(info.name)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // While it is dragged out, its place stays empty.
        guard !isDragging else { return }
        if isHovered || isPressed || isOpen {
            NSColor.labelColor.withAlphaComponent(isPressed || isOpen ? 0.2 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let side: CGFloat = info.icon.isTemplate ? 16 : 20
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        if info.icon.isTemplate {
            // Symbols take the label colour, like the menu bar draws them.
            let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
                self.info.icon.draw(in: drawRect)
                NSColor.labelColor.set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        } else {
            info.icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: info.isRunning ? 1 : 0.45)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
            return
        }
        isPressed = true
        mouseDownPoint = event.locationInWindow
    }

    // The drag is tracked here rather than with a dragging session: over the top of the
    // screen a dragging session opens Mission Control, and nothing else takes the item anyway.
    // The view keeps getting the mouse events after the pointer leaves the drawer.
    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        if isDragging {
            moveDrag(to: location)
            return
        }
        guard isPressed, let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4, let window else { return }
        isPressed = false
        let image = DragImageWindow(image: snapshot(), from: window.convertToScreen(convert(bounds, to: nil)))
        image.orderFrontRegardless()
        dragImage = image
        isDragging = true
        moveDrag(to: location)
    }

    private func moveDrag(to location: NSPoint) {
        dragImage?.center(at: location)
        canDrop = onDragMove?(location) ?? false
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        if isDragging {
            let location = NSEvent.mouseLocation
            let image = dragImage
            dragImage = nil
            // Let go over the menu bar it goes there; anywhere else it slides back.
            if canDrop || (onDragMove?(location) ?? false) {
                image?.orderOut(nil)
            } else {
                image?.slideBack()
            }
            isDragging = false
            isHovered = false
            canDrop = false
            onDragEnd?(location)
            return
        }
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(with: event) }

    // MARK: Dragging out to the menu bar

    /// The icon as drawn, to drag around.
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    private func showMenu(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open \(info.name)") { [weak self] in self?.onOpen?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove from Chest") { [weak self] in self?.onRemove?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension NSImage {
    /// Stretchable rounded-rect mask for `NSVisualEffectView.maskImage`. A layer corner radius
    /// only clips the view's own drawing; the mask also clips the blur behind the window, and
    /// the window shadow follows it.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// An item's icon following the pointer while it is dragged out of the drawer.
@MainActor
private final class DragImageWindow: NSPanel {
    private let home: NSRect

    init(image: NSImage, from frame: NSRect) {
        home = frame
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        alphaValue = 0.85
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    func center(at point: NSPoint) {
        setFrameOrigin(NSPoint(x: (point.x - frame.width / 2).rounded(), y: (point.y - frame.height / 2).rounded()))
    }

    /// Goes back to the drawer, then away.
    func slideBack() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(home, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }
}

/// The chest to drop into, hanging under the dot while a menu bar item is ⌘-dragged. The
/// dot itself cannot be the target: MenuBarAgent slides it aside to make room for the item.
@MainActor
final class DropPanel: NSPanel {
    private static let size = NSSize(width: 150, height: 64)
    private let effectView = NSVisualEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Drop in Chest")

    /// The pointer is over it: it lights up.
    var isTargeted = false {
        didSet {
            guard isTargeted != oldValue else { return }
            effectView.layer?.backgroundColor = isTargeted ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
            effectView.layer?.borderColor = (isTargeted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            effectView.layer?.borderWidth = isTargeted ? 2 : 0.5
            icon.symbolConfiguration = .init(pointSize: isTargeted ? 24 : 20, weight: .regular)
            icon.image = NSImage(systemSymbolName: isTargeted ? "archivebox.fill" : "archivebox", accessibilityDescription: nil)
        }
    }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // The drag belongs to MenuBarAgent; Chest only watches where it goes.
        ignoresMouseEvents = true

        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.maskImage = .roundedMask(radius: 12)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = effectView

        icon.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(under dot: CGRect, on screen: NSScreen) {
        isTargeted = false
        let origin = MenuBarGeometry.drawerOrigin(size: Self.size, under: dot, in: screen.frame)
        setFrame(NSRect(origin: origin, size: Self.size), display: true)
        guard !isVisible else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        isTargeted = false
    }
}

/// A thin bar in the menu bar where an item dragged out of the drawer will go.
@MainActor
final class InsertionMarker: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.cornerRadius = 1.5
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    /// Shows the bar at `x` in `menuBar` (Cocoa coordinates).
    func show(at x: CGFloat, in menuBar: CGRect) {
        setFrame(NSRect(x: (x - 1.5).rounded(), y: menuBar.minY + 4, width: 3, height: menuBar.height - 8), display: true)
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }
}
