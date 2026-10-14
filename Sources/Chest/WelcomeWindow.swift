import AppKit
import Combine
import SwiftUI

/// First-launch window: what Chest does, how to use it, and what it needs, each with its
/// live status: Accessibility, with a button that opens its pane of System Settings, and the
/// two protected files, each with a button that asks for it (`FileAccess`).
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView(onDone: { [weak self] in self?.close() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Chest"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Size to the content before centring; the hosting view sizes itself lazily.
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is a request that a frontmost app may decline (a terminal running
        // `swift run`, say); the window shows either way.
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }
}

private struct WelcomeView: View {
    let onDone: () -> Void

    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasFiles = Dictionary(uniqueKeysWithValues: ProtectedFile.allCases.map { ($0, Permissions.hasFile($0)) })
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AppIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chest").font(.title2.weight(.semibold))
                    Text("Tuck menu bar items away, open them when you need them.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Step(symbol: "command", text: "Hold ⌘ and drag a menu bar item onto the chest that appears under the dot to keep it in the drawer, or leave it left of the dot to hide it there.")
                Step(symbol: "circle.fill", text: "Click the dot to bring back the hidden items and open the drawer.")
                Step(symbol: "cursorarrow.click", text: "Click an item in the drawer to use it. Drag it to the menu bar to put it back.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Chest needs Accessibility and two files").font(.headline)
                PermissionRow(
                    title: "Accessibility",
                    detail: "To see where menu bar items are, and to open them from the drawer.",
                    isGranted: hasAccessibility,
                    actionTitle: "Open Settings…",
                    action: Permissions.requestAccessibility
                )
                ForEach(ProtectedFile.allCases, id: \.self) { file in
                    PermissionRow(
                        title: file.title,
                        detail: file.detail,
                        isGranted: hasFiles[file] ?? false,
                        actionTitle: "Choose File…",
                        action: { FileAccess.choose(file) { hasFiles[file] = $0 } }
                    )
                }
            }

            HStack {
                Spacer()
                Button(hasAccessibility && !hasFiles.values.contains(false) ? "Get Started" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 460)
        .onReceive(refresh) { _ in
            hasAccessibility = Permissions.hasAccessibility
            for file in ProtectedFile.allCases { hasFiles[file] = Permissions.hasFile(file) }
        }
    }
}

/// Chest's own icon. A build run outside the app bundle (`swift run`) has none, so it shows
/// the chest symbol instead.
private struct AppIcon: View {
    var body: some View {
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
        } else {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
        }
    }
}

private struct Step: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isGranted {
                Text("Granted").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(actionTitle, action: action)
            }
        }
    }
}
