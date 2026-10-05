import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ChestController?
    private let welcome = WelcomeWindowController()
    private var signalSources: [DispatchSourceSignal] = []
    private static let didWelcomeKey = "didShowWelcome"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.announceFullDiskAccessUse()
        let controller = ChestController()
        controller.onNeedsPermissions = { [weak self] in self?.welcome.show() }
        self.controller = controller

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.didWelcomeKey) || !Permissions.allGranted {
            defaults.set(true, forKey: Self.didWelcomeKey)
            welcome.show()
        }
        quitOnSignals()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.restoreAll()
    }

    /// Ctrl-C in the terminal (`swift run`) and `kill` quit like the Quit menu item does, so
    /// the hidden items come back. A force quit or a crash cannot be caught; the items stay
    /// switched off in System Settings until Chest runs again.
    private func quitOnSignals() {
        for code in [SIGINT, SIGTERM] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
