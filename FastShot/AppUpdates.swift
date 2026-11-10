import SwiftUI
#if !SWIFT_PACKAGE
import Sparkle
#endif

// SwiftPM remains a dependency-free test harness; updates belong to the installed app bundle.
@Observable final class AppUpdates {
    private(set) var isConfigured = false
    private(set) var canCheckForUpdates = false
    #if !SWIFT_PACKAGE
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    #endif

    func start() {
        #if !SWIFT_PACKAGE
        guard controller == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        isConfigured = true
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let allowed = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = allowed }
        }
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if !SWIFT_PACKAGE
        controller?.checkForUpdates(nil)
        #endif
    }
}

struct CheckForUpdatesButton: View {
    let updates: AppUpdates
    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
