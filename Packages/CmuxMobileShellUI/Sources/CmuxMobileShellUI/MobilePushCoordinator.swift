#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation
import UIKit
import UserNotifications

/// Bridges APNs push between the app-target `AppDelegate` and the mobile shell
/// store: drives opt-in registration, hands device tokens to the injected
/// ``CmuxAuthRuntime/PushRegistrationService``, and routes foreground
/// presentation + taps to the active ``CMUXMobileShellStore`` for "mirror macOS"
/// suppression and deep-link.
///
/// The coordinator is the seam between the `UIApplicationDelegate` (which must
/// own `UNUserNotificationCenterDelegate`) and the per-scene store. Constructed
/// once at the composition root with an injected push-registration service and
/// injected into the SwiftUI environment + the app delegate; no singleton.
@MainActor
@Observable
public final class MobilePushCoordinator {
    private let registration: any PushRegistering
    private let analytics: any AnalyticsEmitting
    /// The system-notification surface used by the cold dismiss lane. Owned here
    /// (not via the store) because a silent dismiss push can wake the app in the
    /// background before any scene — and therefore any store — exists.
    private let deliveredNotificationClearer: any DeliveredNotificationClearing
    // UserDefaults is Apple-documented thread-safe; a synchronous read mirrors
    // the opt-in flag for the menu UI without awaiting the actor service.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let enabledKey = "cmux.notifications.pushEnabled"

    /// APNs `aps.category` the web sets on every cmux terminal push (see
    /// `CMUX_APNS_CATEGORY` in `web/services/apns/payload.ts`). The matching
    /// ``UNNotificationCategory`` registered below carries
    /// `.customDismissAction`, so a swipe/clear delivers
    /// `UNNotificationDismissActionIdentifier` to the app and we can forward the
    /// dismiss to the Mac. Keep these two ids in sync.
    public static let dismissSyncCategoryIdentifier = "cmux.terminal"

    @ObservationIgnored private weak var store: CMUXMobileShellStore?

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - analytics: The injected fire-and-forget analytics emitter. Defaults to
    ///     ``NoopAnalytics`` for previews/tests.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    ///   - deliveredNotificationClearer: The system-notification seam used to
    ///     remove banners for a background dismiss push. Defaults to the real
    ///     `UNUserNotificationCenter`-backed conformance.
    public init(
        registration: any PushRegistering,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        defaults: UserDefaults = .standard,
        deliveredNotificationClearer: any DeliveredNotificationClearing = SystemDeliveredNotificationClearer()
    ) {
        self.registration = registration
        self.analytics = analytics
        self.defaults = defaults
        self.deliveredNotificationClearer = deliveredNotificationClearer
    }

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Install the notification-center delegate, register the dismiss-sync
    /// notification category, and, if already opted in, re-assert remote
    /// registration so a rotated token re-uploads. Call once at launch from the
    /// AppDelegate.
    public func configure(delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // The category must carry `.customDismissAction` so a swipe/clear of a
        // cmux banner delivers `UNNotificationDismissActionIdentifier` to the
        // delegate; that is what lets us tell the Mac the user dismissed it.
        let dismissSyncCategory = UNNotificationCategory(
            identifier: Self.dismissSyncCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([dismissSyncCategory])
        if isEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Opt in: request system authorization, register for remote notifications,
    /// and persist the flag. Returns whether authorization was granted.
    @discardableResult
    public func enable() async -> Bool {
        let priorStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        // Only an undetermined status produces a real OS prompt; gate the
        // "shown" event on it so a re-toggle of an already-decided status does
        // not log a phantom prompt.
        if priorStatus == .notDetermined {
            analytics.capture("ios_push_optin_prompt_shown", [
                "trigger": .string("settings_toggle"),
                "prior_authorization_status": .string("not_determined"),
            ])
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            analytics.capture("ios_push_optin_declined", [
                "trigger": .string("settings_toggle"),
                "was_os_level_predenied": .bool(priorStatus == .denied),
            ])
            return false
        }
        analytics.capture("ios_push_optin_granted", ["trigger": .string("settings_toggle")])
        await registration.setEnabled(true)
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        await registration.setEnabled(false)
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        await registration.register(deviceToken: token)
    }

    /// Re-upload the cached token when possible (e.g. after sign-in).
    public func syncTokenIfPossible() async {
        await registration.syncTokenIfPossible()
    }

    /// Remove the cached token from the server (on sign-out).
    public func unregisterFromServer() async {
        await registration.unregisterFromServer()
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        guard let store, let workspaceId,
              store.selectedWorkspaceID?.rawValue == workspaceId else {
            return true
        }
        if let surfaceId {
            return store.selectedTerminalID?.rawValue != surfaceId
        }
        return false
    }

    /// Deep-link to the workspace/terminal a tapped notification refers to.
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        guard let store else {
            analytics.capture("ios_push_deeplink_failed", ["reason": .string("no_store")])
            return
        }
        if let workspaceId {
            store.selectedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceId)
        }
        if let surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        analytics.capture("ios_push_deeplink_resolved", [
            "resolved_workspace": .bool(workspaceId != nil),
            "resolved_surface": .bool(surfaceId != nil),
        ])
    }

    /// Forward a phone-side notification dismissal to the paired Mac so it marks
    /// the notification read and clears its own banner. Fire-and-forget over the
    /// attach channel; carries only the opaque notification id, never content.
    /// - Parameter notificationId: The stable id of the dismissed notification.
    ///   For a remote push this is `request.identifier` (the `apns-collapse-id`),
    ///   with `cmux.notificationId` as a fallback.
    public func handleDismiss(notificationId: String?) async {
        guard let store,
              let notificationId,
              !notificationId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await store.dismissNotification(ids: [notificationId])
    }

    /// Handle a silent Mac→iOS dismiss push (the cold lane: the Mac cleared
    /// notifications while no phone was live-attached). Removes the matching
    /// delivered banners directly through the system-notification seam — the
    /// store may not exist yet on a background wake — while the badge was
    /// already applied by the system from the push's `aps.badge`.
    /// - Parameter ids: The dismissed stable notification ids from
    ///   `cmux.dismissedIds`.
    public func handleRemoteDismiss(ids: [String]) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        deliveredNotificationClearer.removeDelivered(ids: trimmed)
    }
}
#endif
