import Foundation

extension MobileHostService {
    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the live `publicHostStatusResult`, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin on the entries present here.
    ///
    /// This also advertises `dogfood.v1`, the agent feedback round-trip
    /// (`dogfood.feedback.submit`). It is advertised on every build type so the
    /// privileged Send Feedback path (offered only to `@manaflow.ai` users on an
    /// active connection) works on Release (beta/prod) too; the sink itself is
    /// still gated by the same-account Stack-auth check the rest of the mobile
    /// data plane enforces.
    nonisolated static var mobileHostCapabilities: [String] {
        var capabilities = [
            "events.v1",
            "notification.dismiss.v1",
            "terminal.bytes.v1",
            "terminal.paste.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
            "dogfood.v1",
        ]
        #if DEBUG
        // `dogfood.v1` is the P1 umbrella (the `dogfood.feedback.submit` sink) and
        // is already advertised unconditionally above so the privileged Send
        // Feedback path works on Release too. `dogfood.checklist`/`dogfood.feedback`
        // are the P2 verbs the floating pane gates on: a P1-only Mac advertises
        // only `dogfood.v1`, so a newer phone skips the checklist subscribe +
        // fetch and never eats a `method_not_found`.
        capabilities.append(contentsOf: ["dogfood.checklist", "dogfood.feedback"])
        #endif
        return capabilities
    }
}
