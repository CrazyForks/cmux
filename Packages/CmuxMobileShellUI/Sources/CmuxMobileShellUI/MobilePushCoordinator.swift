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

    /// The set of workspace ids muted for phone push, as an observation-tracked
    /// stored property so SwiftUI re-renders the workspace list when a row is
    /// muted/unmuted. Hydrated from the registration service at launch (the
    /// service owns the persisted source of truth) and kept in lock-step on
    /// every toggle. Unlike ``isEnabled`` (a deliberately non-observable
    /// `UserDefaults` mirror), this must be observable: the list's per-row mute
    /// indicator and context-menu label derive from it directly.
    public private(set) var mutedWorkspaceIDs: Set<String> = []

    /// The single in-flight server mute hydration, owned so it can be cancelled.
    /// Starting a new refresh or signing out cancels the prior one, so a stale
    /// fetch (e.g. one begun under a previous account whose tokens are briefly
    /// still valid during sign-out) can never write its result back. Using
    /// structured ownership + cancellation instead of a generation counter keeps
    /// exactly one authoritative refresh and avoids a stale task performing any
    /// destructive cleanup. `@ObservationIgnored`: it is lifecycle, not rendered.
    @ObservationIgnored private var mutedRefreshTask: Task<Void, Never>?
    /// In-flight per-workspace mute toggle syncs, owned so sign-out can cancel
    /// any tap that has not yet reached the registration actor. Without this, a
    /// toggle task created just before an account switch could run under the next
    /// account and persist the previous screen's workspace id as that account's
    /// mute. Cancelling them on sign-out (plus the service's per-user key) keeps
    /// a tap from leaking across accounts. Keyed by a stable `UUID` so the task
    /// body removes its own entry by id without capturing the task handle (which
    /// Swift 6 strict concurrency rejects as a captured-mutable-var reference).
    @ObservationIgnored private var muteToggleTasks: [UUID: Task<Void, Never>] = [:]
    /// A tap whose navigation could not complete yet. On a cold launch the
    /// notification-center delegate delivers the tap before the root view has
    /// mounted (no store bound yet), and even once bound the tapped workspace
    /// is not in the store until the Mac attach finishes. The tap is parked
    /// here and re-applied from ``bind(store:)`` and ``workspacesDidChange()``
    /// until the target exists or the request expires.
    private struct PendingDeeplink {
        let workspaceId: String?
        let surfaceId: String?
        let createdAt: Date
    }

    @ObservationIgnored private var pendingDeeplink: PendingDeeplink?
    /// Bounded so a tap from long ago cannot yank the user out of whatever
    /// they navigated to in the meantime, but generous enough to cover cold
    /// launch plus sign-in plus a slow attach.
    private static let pendingDeeplinkLifetime: TimeInterval = 120
    @ObservationIgnored private let now: () -> Date

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - analytics: The injected fire-and-forget analytics emitter. Defaults to
    ///     ``NoopAnalytics`` for previews/tests.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    ///   - now: Clock seam for the pending-deeplink expiry. Defaults to
    ///     `Date.init`.
    public init(
        registration: any PushRegistering,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.registration = registration
        self.analytics = analytics
        self.defaults = defaults
        self.now = now
    }

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
        applyPendingDeeplinkIfReady()
    }

    /// Re-apply a parked notification tap once its target can exist. Called by
    /// the root view whenever the store's workspace list changes (the list is
    /// empty until the Mac attach completes).
    public func workspacesDidChange() {
        applyPendingDeeplinkIfReady()
    }

    /// Install the notification-center delegate, register the dismiss-sync
    /// notification category, and, if already opted in, re-assert remote
    /// registration so a rotated token re-uploads. Call once at launch from the
    /// AppDelegate.
    ///
    /// This never requests notification authorization: the OS prompt only ever
    /// fires from ``enable()`` (the explicit user opt-in), so a fresh launch on a
    /// phone that has not opted in shows no permission dialog.
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
        // Hydrate the observable muted set from the persisted source of truth so
        // the workspace list reflects prior mutes immediately on launch.
        Task { mutedWorkspaceIDs = await registration.mutedWorkspaceIDs }
    }

    /// Whether `workspaceId` is currently muted for phone push.
    public func isWorkspaceMuted(_ workspaceId: String) -> Bool {
        mutedWorkspaceIDs.contains(workspaceId)
    }

    /// Pull the authoritative muted set from the server and republish the
    /// observable from it. Call on sign-in: the server set is keyed by the
    /// authenticated user, so this overwrites any locally cached set from a
    /// previous account instead of re-uploading it. A network failure / signed
    /// out state keeps the existing local set (no clobber to empty).
    ///
    /// Owns a single cancellable refresh task: a new refresh or a sign-out
    /// cancels any prior one, and a cancelled fetch never writes its (stale)
    /// result back, so a refresh begun under a previous account can't repopulate
    /// the cache after sign-out.
    public func refreshMutedWorkspacesFromServer() {
        // Persistence is namespaced per user in the service, so a stale fetch can
        // never leak across accounts. This task guards only the shared OBSERVABLE
        // (the live UI value): a new refresh or a sign-out cancels the prior one
        // so a fetch begun under a previous account can't publish its set into the
        // current session's list.
        mutedRefreshTask?.cancel()
        mutedRefreshTask = Task { [weak self] in
            guard let self else { return }
            let serverSet = await self.registration.hydrateMutedWorkspacesFromServer()
            guard !Task.isCancelled else { return }
            self.mutedWorkspaceIDs = serverSet
        }
    }

    /// Set phone-push mute for a workspace to an explicit state. Updates the
    /// observable set optimistically (so the list re-renders at once), persists,
    /// and syncs the full muted set to the server, where delivery is actually
    /// gated. Honors the requested `muted` value rather than toggling, so a stale
    /// row snapshot or a state change while a context menu is open can never flip
    /// the workspace to the wrong state.
    public func setWorkspaceMuted(_ workspaceId: String, muted: Bool) {
        if muted == mutedWorkspaceIDs.contains(workspaceId) { return }
        if muted {
            mutedWorkspaceIDs.insert(workspaceId)
        } else {
            mutedWorkspaceIDs.remove(workspaceId)
        }
        analytics.capture("ios_push_workspace_mute_toggled", ["muted": .bool(muted)])
        // Own the toggle so sign-out can cancel a tap that has not yet reached the
        // registration actor, so it can't run under (and write for) the next
        // account. Keyed by a stable id captured by value (no task self-capture).
        let id = UUID()
        muteToggleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.muteToggleTasks[id] = nil }
            // If sign-out cancelled this before it ran, do not write.
            guard !Task.isCancelled else { return }
            await self.registration.setWorkspaceMuted(workspaceId, muted: muted)
            guard !Task.isCancelled else { return }
            // Reconcile against the persisted authoritative set in case a
            // concurrent change interleaved.
            self.mutedWorkspaceIDs = await self.registration.mutedWorkspaceIDs
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

    /// Remove the cached token from the server (on sign-out), authenticating
    /// with the credentials captured before the local-first sign-out cleared
    /// the live token store.
    public func unregisterFromServer(accessToken: String?, refreshToken: String?) async {
        await registration.unregisterFromServer(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Sign-out cleanup: reset the observable to empty and remove the device
    /// token server-side. The persisted muted set does NOT need clearing: it is
    /// namespaced by user id in the service, so the signed-out account's mutes
    /// stay under their own key (restored on their next sign-in) and the next
    /// account reads its own empty/namespaced key. Cancelling the refresh task
    /// stops a stale fetch from re-publishing the prior account's set into the
    /// now-empty observable.
    public func handleSignedOut() async {
        mutedRefreshTask?.cancel()
        mutedRefreshTask = nil
        // Cancel any pending toggle taps so they can't run under the next account.
        for task in muteToggleTasks.values { task.cancel() }
        muteToggleTasks.removeAll()
        mutedWorkspaceIDs = []
        await registration.unregisterFromServer()
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// workspace is muted, or when the user is already viewing the terminal the
    /// notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        // Honor the per-workspace mute locally too: the server is the primary
        // gate, but a push can already be in flight when the mute PUT lands, or
        // the server can fail open on a mute-lookup error, so a muted workspace
        // must never surface a foreground banner/sound. Mirrors the server's
        // `shouldDeliverToWorkspace`.
        guard pushShouldDeliver(workspaceId: workspaceId, muted: mutedWorkspaceIDs) else {
            return false
        }
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
    ///
    /// The tap is parked first and applied through one path: a cold launch
    /// delivers the tap before the root view has bound a store, and a
    /// warm-but-detached app has not loaded the workspace yet. Navigating
    /// immediately in those states is what stranded users on the workspaces
    /// home screen.
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        pendingDeeplink = PendingDeeplink(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            createdAt: now()
        )
        applyPendingDeeplinkIfReady()
    }

    /// Apply the parked tap if its target can be navigated to right now;
    /// otherwise keep it parked for the next ``bind(store:)`` or
    /// ``workspacesDidChange()``.
    private func applyPendingDeeplinkIfReady() {
        guard let pending = pendingDeeplink else { return }
        guard now().timeIntervalSince(pending.createdAt) < Self.pendingDeeplinkLifetime else {
            pendingDeeplink = nil
            analytics.capture("ios_push_deeplink_failed", ["reason": .string("expired")])
            return
        }
        guard let store else { return }

        // Resolve the workspace to navigate to: the explicit target, or for a
        // surface-only tap the workspace that owns the terminal. Unresolvable
        // means "not loaded yet": stay parked for the next topology change so
        // the tap is never spent on a selection that cannot navigate.
        let workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            workspaceTarget = MobileWorkspacePreview.ID(rawValue: workspaceId)
            guard store.workspaces.contains(where: { $0.id == workspaceTarget }) else { return }
        } else if let surfaceId = pending.surfaceId {
            guard let owner = store.workspaceID(containingSurfaceID: surfaceId) else { return }
            workspaceTarget = owner
        } else {
            pendingDeeplink = nil
            return
        }

        if let surfaceId = pending.surfaceId,
           !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            // The workspace is here but its terminal snapshot is not (still
            // loading, or the terminal was closed). Land the user in the right
            // workspace now and keep only the surface part parked so it can
            // resolve if the terminal arrives, bounded by the same expiry.
            store.navigateToWorkspaceForDeeplink(workspaceTarget)
            pendingDeeplink = PendingDeeplink(
                workspaceId: nil,
                surfaceId: surfaceId,
                createdAt: pending.createdAt
            )
            return
        }

        store.navigateToWorkspaceForDeeplink(workspaceTarget)
        if let surfaceId = pending.surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        pendingDeeplink = nil
        analytics.capture("ios_push_deeplink_resolved", [
            "resolved_workspace": .bool(pending.workspaceId != nil),
            "resolved_surface": .bool(pending.surfaceId != nil),
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
}
#endif
