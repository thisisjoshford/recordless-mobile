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
    @State private var app: AppModel
    @State private var flow: AppFlow

    init() {
        let app = AppModel()
        _app = State(initialValue: app)
        _flow = State(initialValue: AppFlow(app: app))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flow)
                .environment(app)
                .environment(app.models)
                .environment(app.recorder)
                .environment(app.vault)
                .environment(app.generator)
                #if DEBUG
                .task { SelfTest.runIfRequested(app); flow.applyDebugScreen() }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Refused (and the notebook left open) while there is unfinished
            // work, so backgrounding never destroys a recording, a notes
            // request or an unsaved transcript. AppModel retries the lock
            // whenever such work ends while the app is still in the background.
            app.scenePhaseChanged(background: phase == .background)
            flow.scenePhaseChanged(phase)
            // Hide content (sheets and covers too) in the app-switcher
            // snapshot and whenever we are not frontmost.
            PrivacyShield.setVisible(phase != .active)
            if phase == .active {
                ActivityMonitor.install { [flow] in flow.noteActivity() }
            }
        }
    }
}
