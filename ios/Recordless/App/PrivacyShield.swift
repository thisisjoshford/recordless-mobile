import SwiftUI
import UIKit

/// Covers every window, including sheets and full-screen covers, whenever
/// the scene isn't active, so the app-switcher snapshot shows nothing. An
/// overlay on the root view can't do this: presentations draw above it.
@MainActor
enum PrivacyShield {
    private static var window: UIWindow?

    static func setVisible(_ visible: Bool) {
        if visible {
            guard window == nil, let scene = activeScene else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            let host = UIHostingController(rootView: PrivacyOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.isHidden = false
            window = w
        } else {
            window?.isHidden = true
            window = nil
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// Reports every touch in the app's windows (without consuming it), for the
/// idle auto-lock.
@MainActor
enum ActivityMonitor {
    static func install(_ onActivity: @escaping @MainActor () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows)
        where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchObserver }) {
            window.addGestureRecognizer(TouchObserver(onActivity))
        }
    }

    private final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let onActivity: @MainActor () -> Void

        init(_ onActivity: @escaping @MainActor () -> Void) {
            self.onActivity = onActivity
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onActivity()
            state = .failed        // observe only
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
