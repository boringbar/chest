import AppKit
import ChestCore

/// A short message hanging under the dot, in the drawer's style, for things the user should
/// know about right away: an item that could not go in, a missing permission. It goes away on
/// its own, at a click elsewhere, or on its button.
@MainActor
final class NoticePanel: NSPanel {
    private let effectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = FirstClickButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var dismissWork: DispatchWorkItem?
    private var monitors: [Any] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.maskImage = .roundedMask(radius: 10)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = effectView

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 280
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(runAction)

        let stack = NSStackView(views: [titleLabel, detailLabel, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 280),
        ])
    }

    override var canBecomeKey: Bool { false }

    func show(title: String, detail: String, action: (String, () -> Void)?, under dot: CGRect, on screen: NSScreen) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        button.title = action?.0 ?? ""
        button.isHidden = action == nil
        self.action = action?.1
        let size = contentView?.fittingSize ?? .zero
        setFrame(NSRect(origin: MenuBarGeometry.drawerOrigin(size: size, under: dot, in: screen.frame), size: size), display: true)
        alphaValue = 1
        orderFrontRegardless()

        removeMonitors()
        let click: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.frame.contains(location) else { return }
                self.dismiss()
            }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { click($0); return $0 },
        ].compactMap { $0 }

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        // Long enough to read two sentences; one with a button waits a little longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 6 : 10), execute: work)
    }

    func dismiss(animated: Bool = true) {
        dismissWork?.cancel()
        removeMonitors()
        guard isVisible else { return }
        guard animated else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    @objc private func runAction() {
        action?()
        dismiss()
    }
}

/// A button that acts on the first click, in a panel that never becomes key.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
