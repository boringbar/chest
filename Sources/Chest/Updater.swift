import Foundation
import Sparkle

/// Updates through Sparkle. Release builds carry `SUFeedURL` and `SUPublicEDKey` in their
/// Info.plist (set by scripts/package.sh); a development build has neither, so the updater
/// stays off and the menu item is hidden.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else {
            controller = nil
            log("updater off: no feed in Info.plist")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
