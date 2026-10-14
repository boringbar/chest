import AppKit

/// Tells when MenuBarAgent lays out the menu bar again: an item appeared, went or changed size.
///
/// MenuBarAgent posts `AXLayoutChanged` on its application element for that, once per menu
/// bar window; subscribing on the windows themselves delivers nothing. What happens inside an
/// item (a clock ticking, Stats redrawing a graph) posts value and title changes instead,
/// which are not watched. Measured on macOS 27.0.1.
@MainActor
final class MenuBarLayoutObserver {
    var onChange: (() -> Void)?
    /// MenuBarAgent started again, and has read the list and the positions afresh.
    var onAgentLaunch: (() -> Void)?

    private nonisolated static let agentBundleID = "com.apple.MenuBarAgent"
    private var observer: AXObserver?
    /// MenuBarAgent's process, watched for its exit.
    private var agentPID: pid_t?
    private var exitSource: DispatchSourceProcess?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        attach()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            // Without Accessibility there was nothing to watch; it may have been granted since.
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.observer == nil else { return }
                    self.attach()
                }
            },
        ]
    }

    private func attach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first else { return }
        watchExit(of: agent.processIdentifier)
        guard AXIsProcessTrusted() else { return }
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<MenuBarLayoutObserver>.fromOpaque(refcon).takeUnretainedValue()
            // The run loop source is on the main run loop.
            MainActor.assumeIsolated { observer.onChange?() }
        }
        var created: AXObserver?
        guard AXObserverCreate(agent.processIdentifier, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        let result = AXObserverAddNotification(created, app, kAXLayoutChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else {
            log("couldn’t watch the menu bar layout: \(result.rawValue)")
            return
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    /// launchd starts MenuBarAgent again when it quits (Refresh Menu Bar does that), but
    /// NSWorkspace posts neither its exit nor its launch: it is not started through Launch
    /// Services. The process itself is watched instead.
    private func watchExit(of pid: pid_t) {
        guard pid != agentPID else { return }
        exitSource?.cancel()
        agentPID = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.agentExited(pid) }
        }
        source.resume()
        exitSource = source
    }

    private func agentExited(_ pid: pid_t) {
        exitSource?.cancel()
        exitSource = nil
        Task { [weak self] in
            // The new process shows up in NSRunningApplication within about two seconds; the
            // old one can be listed for a moment longer.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first,
                      agent.processIdentifier != pid else { continue }
                log("MenuBarAgent started again")
                self.attach()
                self.onAgentLaunch?()
                return
            }
        }
    }
}
