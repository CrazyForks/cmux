import CmuxMobileBrowser
import CmuxMobileShell
import SwiftUI
#if os(iOS)
import CmuxMobileShellModel
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    #if os(iOS) && DEBUG
    /// The floating DEV dogfood pane model, built once next to the store and
    /// wired into it so the dedicated `dogfood.checklist` subscription feeds it.
    /// DEBUG-only; absent in release builds.
    @State private var dogfoodFeedbackModel: DogfoodFeedbackModel
    #endif
    /// Phone-local browser surfaces, owned for the app's lifetime and injected
    /// into the environment so the workspace detail view can present a browser
    /// pane without threading the store through every intermediate view. Browser
    /// state lives here (not in the shell store) because, unlike terminals, it
    /// has no Mac-side counterpart and must survive `workspace.updated` re-syncs.
    @State private var browserStore: BrowserSurfaceStore
    #if os(iOS)
    /// The first-run onboarding "seen" flag store, gating the one-time onboarding
    /// screen ahead of the never-paired add-device state.
    private let onboardingStore: MobileOnboardingStore
    #endif

    #if os(iOS)
    /// Creates the app view.
    /// - Parameters:
    ///   - store: The shell store backing the workspace UI.
    ///   - browserStore: The phone-local browser surface store injected into the
    ///     environment for workspace detail browser panes.
    ///   - onboardingStore: The first-run onboarding "seen" flag store. Defaults
    ///     to a `.standard`-backed store marked already-seen, so SwiftUI previews
    ///     and ad-hoc construction never present onboarding.
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceSeen: true)
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
        self.onboardingStore = onboardingStore
        #if DEBUG
        let model = DogfoodFeedbackModel(submitter: DogfoodFeedbackUISubmitter(store: store))
        store.setDogfoodFeedbackModel(model)
        _dogfoodFeedbackModel = State(initialValue: model)
        #endif
    }
    #else
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(store: store, onboardingStore: onboardingStore)
            .environment(browserStore)
            #if DEBUG
            // Host the floating dogfood pane as a normal in-hierarchy overlay so
            // SwiftUI's native hit-testing delivers BOTH the pill's tap and drag.
            // The previous passthrough `UIWindow` owned its own `hitTest`, which
            // repeatedly returned `nil` on the pill's own touches and killed the
            // gestures. An `.overlay` whose only hittable content is the pill/card
            // (everything else is `Color.clear` with hit-testing off) lets the app
            // beneath receive every other touch with no custom window. It sits
            // below SwiftUI `.sheet`s (the pairing + feedback sheets), which is an
            // acceptable trade for a DEV pane.
            .overlay {
                DogfoodPaneOverlayView(model: dogfoodFeedbackModel)
            }
            #endif
        #else
        CMUXMobileRootView(store: store)
            .environment(browserStore)
        #endif
    }
}
