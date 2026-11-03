import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Reconnect the background download session as early as possible.
        _ = ModelStore.shared
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelStore.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct RecordlessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.models)
                .environment(app.recorder)
                .environment(app.vault)
                .environment(app.generator)
                .overlay {
                    // Hide content in the app-switcher snapshot and whenever we are not frontmost.
                    if scenePhase != .active { PrivacyOverlay() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Refused (and the notebook left open) while there is unfinished
            // work, so backgrounding never destroys a recording, a notes
            // request or an unsaved transcript. AppModel retries the lock
            // whenever such work ends while the app is still in the background.
            app.scenePhaseChanged(background: phase == .background)
        }
    }
}
