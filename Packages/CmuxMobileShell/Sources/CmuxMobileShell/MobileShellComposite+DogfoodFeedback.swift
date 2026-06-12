internal import CmuxMobileDiagnostics
internal import CmuxMobileShellModel
internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Privileged direct-to-agent feedback round-trip: export the structured
    /// diagnostic log, package it with the supplied debug-log text, visible
    /// terminal text, and an optional freeform note, and submit it to the paired
    /// Mac's `dogfood.feedback.submit` sink so the existing watcher under
    /// `~/.cache/cmux-dogfood-feedback/` catches it.
    ///
    /// This is the privileged path of the Send Feedback feature: it is offered
    /// only to `@manaflow.ai` users on an active mobile-host connection (see
    /// ``MobileFeedbackRoute/resolve(email:hasActiveMacConnection:hostSupportsAgentSink:)``), and is NOT
    /// `#if DEBUG`-gated, so it works on Release (beta/prod) builds for the team.
    ///
    /// The structured log is exported here (the store owns ``diagnosticLog``);
    /// the string snapshots are gathered by the caller on the UI layer, where the
    /// `GhosttySurfaceView`/`MobileDebugLog` accessors live. Fire-and-forget; a
    /// transport failure is logged and surfaced via the returned `Bool`.
    ///
    /// - Parameters:
    ///   - text: An optional freeform note from the user.
    ///   - debugLogText: The string debug-log snapshot (from `MobileDebugLog`).
    ///   - terminalText: The visible terminal text (from `GhosttySurfaceView`).
    ///   - buildStamp: The build-identity stamp (build type + version + OS +
    ///     device) written into the bundle. Defaults to the diagnostic log's
    ///     stamp when not supplied.
    /// - Returns: `true` when the Mac acknowledged the bundle.
    @discardableResult
    public func submitPrivilegedAgentFeedback(
        text: String,
        debugLogText: String,
        terminalText: String,
        buildStamp: String? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        let diagnosticBlob = await diagnosticLog?.export() ?? Data()
        let buildStamp = buildStamp ?? diagnosticLog?.buildStamp ?? ""
        let clientID = clientID
        // Cap inputs and build the (potentially multi-MiB) combined blob +
        // base64 + JSON request OFF the main actor: the store is `@MainActor`, so
        // doing the concat/encode here would block the UI on a large bundle. A
        // detached task returns the finished request bytes (`Data` is `Sendable`).
        let request: Data?
        do {
            request = try await Task.detached(priority: .utility) { () -> Data in
                try Self.buildDogfoodFeedbackRequest(
                    text: text,
                    debugLogText: debugLogText,
                    terminalText: terminalText,
                    buildStamp: buildStamp,
                    clientID: clientID,
                    diagnosticBlob: diagnosticBlob
                )
            }.value
        } catch {
            mobileShellLog.error("dogfood feedback encode failed error=\(String(describing: error), privacy: .public)")
            return false
        }
        guard let request else { return false }
        do {
            _ = try await client.sendRequest(request)
            return true
        } catch {
            mobileShellLog.error("dogfood feedback submit failed error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Client-side caps mirroring the Mac sink, applied before any large
    /// allocation so a huge debug log or note can't be encoded into a multi-MiB
    /// request on the phone. `nonisolated` so the off-main request builder can
    /// read them.
    nonisolated private static let dogfoodFeedbackMaxTextChars = 16_384
    nonisolated private static let dogfoodFeedbackMaxTerminalChars = 262_144
    nonisolated private static let dogfoodFeedbackMaxDebugLogChars = 1_048_576

    /// Combine the structured + string diagnostics into one self-contained blob,
    /// base64-encode it, and build the RPC request — all off the main actor.
    ///
    /// The string debug log rides inside the same diagnostic file as the compact
    /// structured rows (rows, a divider, then the human-readable log) so the Mac
    /// bundle is self-contained. Inputs are size-capped first.
    nonisolated private static func buildDogfoodFeedbackRequest(
        text: String,
        debugLogText: String,
        terminalText: String,
        buildStamp: String,
        clientID: String,
        diagnosticBlob: Data
    ) throws -> Data {
        let cappedText = String(text.prefix(dogfoodFeedbackMaxTextChars))
        let cappedTerminal = String(terminalText.prefix(dogfoodFeedbackMaxTerminalChars))
        let cappedDebugLog = String(debugLogText.prefix(dogfoodFeedbackMaxDebugLogChars))
        var combined = diagnosticBlob
        if !cappedDebugLog.isEmpty {
            combined.append(Data("\n----- mobile debug log -----\n".utf8))
            combined.append(Data(cappedDebugLog.utf8))
        }
        return try MobileCoreRPCClient.requestData(
            method: "dogfood.feedback.submit",
            params: [
                "text": cappedText,
                "terminal_text": cappedTerminal,
                "build_stamp": buildStamp,
                "diagnostic_blob_base64": combined.base64EncodedString(),
                "client_id": clientID,
            ]
        )
    }
}

// MARK: - Dogfood answers cap + checklist (P2)

extension MobileShellComposite {
    /// Return the answers JSON as a UTF-8 string capped under `maxBytes`, dropping
    /// the freeform note (not the structured MC answers) when needed.
    ///
    /// The MC answers are the dogfooder's actual responses and must never be lost
    /// silently, so when the encoded payload is over the cap this re-encodes the
    /// same answers with an empty note (the note also rides in the capped `text`
    /// field). Returns `nil` when there is no answers payload, the payload cannot
    /// be decoded, or even the note-free encoding is still over the cap (a
    /// pathologically large agent checklist — the structured rows themselves are
    /// bounded by the Mac's checklist size cap, so this is a defensive backstop).
    ///
    /// `internal` (not `private`) so the byte-cap-preserves-answers behavior is
    /// testable without a live transport.
    nonisolated static func cappedAnswersJSONString(_ answersJSON: Data?, maxBytes: Int) -> String? {
        guard let answersJSON else { return nil }
        if answersJSON.count <= maxBytes {
            return String(data: answersJSON, encoding: .utf8)
        }
        // Over the cap: the note is the only unbounded field. Re-encode keeping
        // the MC answers but dropping the note.
        guard let decoded = try? DogfoodFeedbackAnswers.decode(answersJSON) else { return nil }
        let noteFree = DogfoodFeedbackAnswers(answers: decoded.answers, note: "")
        guard let reEncoded = try? noteFree.encode(), reEncoded.count <= maxBytes else { return nil }
        return String(data: reEncoded, encoding: .utf8)
    }

    // MARK: - Dogfood checklist (P2)

    #if DEBUG
    /// The event topic the Mac pushes agent checklists on.
    nonisolated private static let dogfoodChecklistTopic = "dogfood.checklist"
    /// The capability the Mac advertises when it can push/serve checklists. A
    /// P1-only Mac omits it, so the phone skips the subscribe + fetch and never
    /// eats a `method_not_found`.
    nonisolated static let dogfoodChecklistCapability = "dogfood.checklist"

    /// Inject the floating pane's model so the dedicated checklist subscription
    /// can feed it. Called once from the composition root after both are built.
    /// - Parameter model: The DEV dogfood pane model.
    public func setDogfoodFeedbackModel(_ model: DogfoodFeedbackModel) {
        dogfoodFeedbackModel = model
    }

    private var dogfoodChecklistStreamID: String {
        "ios-dogfood-checklist-\(clientID)"
    }

    /// Start the dedicated, durable ``dogfood.checklist`` subscription for the
    /// active connection, then pull the current checklist once so a checklist the
    /// agent pushed *before* this device subscribed is not missed (the
    /// subscribe-after-push race).
    ///
    /// This is intentionally separate from ``startTerminalRefreshPolling()``: the
    /// terminal stream is re-subscribed every ~9s by the render-grid liveness
    /// watchdog, which would repeatedly drop a topic piggybacked on it. A
    /// dedicated stream_id + listener coexists with the terminal stream (both the
    /// client session and the Mac host demux subscriptions by topic / stream_id).
    func startDogfoodChecklistSubscription() {
        guard let client = remoteClient else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard dogfoodChecklistListenerTask == nil else { return }
        let topics: Set<String> = [Self.dogfoodChecklistTopic]
        dogfoodChecklistListenerTask = Task { @MainActor [weak self] in
            defer { self?.dogfoodChecklistListenerTask = nil }
            guard let self else { return }
            // Gate on the Mac advertising the capability so a P1-only Mac is a
            // no-op (no subscribe, no fetch). The flag is parsed from the host
            // status the terminal path already resolved; no extra status RPC.
            guard self.supportsDogfoodChecklist else { return }
            let stream = await client.subscribe(to: topics)
            let subscribed = await self.requestDogfoodChecklistSubscription(client: client)
            guard subscribed else { return }
            // Close the subscribe-after-push race: pull the current checklist now.
            await self.fetchDogfoodChecklist(client: client)
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard self.remoteClient === client else { return }
                if event.topic == Self.dogfoodChecklistTopic {
                    self.dogfoodFeedbackModel?.applyChecklistPayload(event.payloadJSON)
                }
            }
        }
    }

    func stopDogfoodChecklistSubscription() {
        dogfoodChecklistListenerTask?.cancel()
        dogfoodChecklistListenerTask = nil
    }

    /// Register the dedicated checklist subscription with the Mac host. Uses a
    /// distinct stream_id so it coexists with the terminal subscription.
    private func requestDogfoodChecklistSubscription(client: MobileCoreRPCClient) async -> Bool {
        do {
            let requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": dogfoodChecklistStreamID,
                    "topics": [Self.dogfoodChecklistTopic],
                ]
            )
            let responseData = try await client.sendRequest(requestData)
            let response = try? MobileEventSubscribeResponse.decode(responseData)
            return !(response?.streamID ?? "").isEmpty
        } catch {
            mobileShellLog.error("dogfood checklist subscribe failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Pull the current checklist via `dogfood.checklist.fetch` and feed it to the
    /// pane model. Best-effort: a missing/old Mac or an unparseable result is a
    /// no-op (the subscription still delivers future pushes). A result that
    /// explicitly reports no checklist (`{"checklist": null}`) clears the pane —
    /// this is the reconnect/missed-clear recovery path, so a phone that still
    /// shows a since-cleared checklist gets cleared on the next fetch.
    private func fetchDogfoodChecklist(client: MobileCoreRPCClient) async {
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "dogfood.checklist.fetch", params: [:])
            )
            switch Self.dogfoodChecklistFetchResult(from: data) {
            case .present(let payload):
                dogfoodFeedbackModel?.applyChecklistPayload(payload)
            case .cleared:
                dogfoodFeedbackModel?.applyChecklist(.empty)
            case .unparseable:
                break
            }
        } catch {
            mobileShellLog.error("dogfood checklist fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The three outcomes of parsing a `dogfood.checklist.fetch` result.
    private enum DogfoodChecklistFetchResult {
        /// A checklist object was present; carries its re-serialized JSON.
        case present(Data)
        /// The Mac explicitly reported no checklist (`{"checklist": null}`).
        case cleared
        /// The result could not be parsed; the caller should leave state as-is.
        case unparseable
    }

    /// Classify a `dogfood.checklist.fetch` result.
    ///
    /// ``MobileCoreRPCClient/sendRequest(_:timeoutNanoseconds:)`` already unwraps
    /// the JSON-RPC envelope and returns only the `result` object, so the data
    /// here is `{"checklist": {...}}` (a checklist) or `{"checklist": null}` (no
    /// checklist), not a nested `{"result": …}`. A present `checklist` object is
    /// re-serialized for the typed decoder; an explicit `null` (or absent key on
    /// a well-formed result) is a `cleared` signal; anything else is
    /// `unparseable`.
    nonisolated private static func dogfoodChecklistFetchResult(from data: Data) -> DogfoodChecklistFetchResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        if let checklist = root["checklist"] as? [String: Any],
           let reSerialized = try? JSONSerialization.data(withJSONObject: checklist) {
            return .present(reSerialized)
        }
        // A well-formed result whose `checklist` is null/absent means the Mac has
        // no checklist set: clear the pane.
        return .cleared
    }
    #endif
}
