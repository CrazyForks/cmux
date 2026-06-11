import Foundation

/// A compact, stable identifier for one kind of diagnostic event.
///
/// The raw value is a small ``UInt16`` so a ``DiagnosticEvent`` stays tiny and
/// an exported log row is a few bytes instead of an interpolated string. New
/// cases append a fresh raw value and never renumber an existing one, so a blob
/// exported by an older build still decodes against a newer reader.
///
/// The cases cover the round-trip seams a dogfooder cares about: connection and
/// pairing outcome, render-grid liveness (silent re-subscribe / stream ended),
/// the input-sequence and byte-gap stalls that surface as "my keystrokes lag",
/// and a generic ``error`` bucket.
public enum DiagnosticEventCode: UInt16, Sendable, Codable, CaseIterable {
    /// A connection attempt to a paired Mac started.
    case connect = 1
    /// Pairing / attach completed successfully.
    case pairOk = 2
    /// Pairing / attach failed.
    case pairFail = 3
    /// The render-grid render queue lagged: a `render_now` waited a long time behind
    /// other ops on the serial output queue before running. `ms` = the measured queue
    /// wait in milliseconds. Round 8 emits this from `GhosttySurfaceView.requestRender`
    /// (the `oq.render.LAG` site) so the render-busy path lands in the export, not just
    /// the time-gated string log — the "terminal frozen, input alive" signal.
    case renderGridLag = 4
    /// The liveness watchdog forced a re-subscribe after a silent stream.
    case livenessResubscribe = 5
    /// The render-grid push/output stream the surface consumes (`for await` in
    /// `GhosttySurfaceRepresentable.Coordinator`) ended. `a` = 1 if it ended on an
    /// explicit cancel (surface teardown), else 0 (the stream finished on its own — a
    /// possible silent wedge where the consumer stops receiving frames while input
    /// still works). Round 8 emits this so a frozen-render Capture&Send shows whether
    /// the render-grid consumer loop is still alive.
    case streamEnded = 6
    /// The local input sequence fell behind the remote-applied sequence.
    case inputSeqBehind = 7
    /// A gap was detected in the delivered terminal byte stream.
    case byteGap = 8
    /// A generic error at an instrumented seam.
    case error = 9

    // MARK: iOS keyboard-input instrumentation (hold-backspace + dictation hunt)
    //
    // These eight codes instrument the iOS terminal keyboard-input path so a
    // device dogfood (which the simulator cannot reproduce — no hold-to-repeat,
    // no dictation) captures *why* hold-backspace and dictation fail. Three blind
    // fix attempts (app-buttons, `hasText=true` UITextView, documentless
    // UIView+UIKeyInput+UITextInput) all left both broken; this round gathers
    // evidence instead of guessing the mechanism. Decode the integer payload with
    // `scripts/decode-ios-diagnostic.py`.

    /// The software keyboard came up (`keyboardWillShow`). `a` = the
    /// ``InputResponderIdentity`` raw value of the current first responder at that
    /// instant (which view the keyboard will actually drive). Confirms or kills
    /// the "``TerminalInputTextView`` is not first responder" hypothesis.
    case inputKeyboardUp = 10
    /// ``TerminalInputTextView/deleteBackward()`` was invoked. Logged on *every*
    /// call, so a single held backspace shows as 1 event (no auto-repeat) versus
    /// many (repeat fires but the byte is lost downstream). `a` = the responder
    /// identity at the moment of the call; `b` = 1 if IME marked text was present
    /// (composition-cancel path), else 0.
    case inputDeleteBackward = 11
    /// A DEL byte (0x7F) actually left the surface toward the Mac
    /// (`onBackspace` → `didProduceInput`). Pairing this with
    /// ``inputDeleteBackward`` proves whether N delete calls produced N emitted
    /// bytes: if both counts match the iOS view is correct and the hunt moves
    /// downstream (transport/Mac/render). `ms` = emitted byte count (always 1).
    case inputBackspaceEmitted = 12
    /// ``TerminalInputTextView/insertText(_:)`` was invoked (typed character, IME
    /// commit, or a dictation result block). `a` = UTF-8 byte length of the text;
    /// `b` = 1 if IME marked text was present, else 0. A dictation result arrives
    /// here as one multi-character block, so a non-trivial `a` after a mic tap
    /// proves dictation fired.
    case inputInsertText = 13
    /// UIKit asked this view for a dictation placeholder
    /// (`insertDictationResultPlaceholder()`). This is the *entry* signal that the
    /// mic was tapped and the framework accepted this view as a dictation target.
    /// Its absence after a mic tap proves dictation never engaged the view at all.
    case inputDictationPlaceholder = 14
    /// UIKit removed the dictation placeholder
    /// (`removeDictationResultPlaceholder(_:willInsertResult:)`). `a` = 1 if a
    /// recognized result will be inserted next, else 0. `a == 0` after a mic tap
    /// means recognition produced nothing for this view.
    case inputDictationRemove = 15
    /// ``TerminalInputTextView/becomeFirstResponder()`` returned. `a` = 1 if the
    /// view became first responder, else 0; `b` = the resulting first-responder
    /// identity (``InputResponderIdentity`` raw value).
    case inputBecomeFirstResponder = 16
    /// A committed block of text was routed to a sink (`emitCommittedText`). `a` =
    /// UTF-8 byte length; `b` = the ``InputCommitSink`` raw value (which delegate
    /// path the text took: per-key input, bracketed paste, or an escape
    /// sequence). Lets a dictation result be traced from `insertText` through to
    /// the byte path that reaches the Mac.
    case inputCommitRouted = 17

    // MARK: iOS composer instrumentation (draft-disappears-on-keyboard-dismiss hunt)
    //
    // These five codes discriminate WHY the iMessage-style composer's draft
    // vanishes after the keyboard opens then closes. The draft text itself lives
    // in the store (`terminalInputText`), so the symptom must be one of: the
    // `isComposerPresented` flag toggled off, the composer view torn down + rebuilt
    // while the flag stayed true, the draft cleared at the store, or (the residual)
    // a `TextField`/`@FocusState` render blank. Logging the flag, the draft length,
    // and the composer view's appear/disappear *independently* of the flag lets a
    // single captured trace name which one happened. Decode with
    // `scripts/decode-ios-diagnostic.py`.

    /// The store's `isComposerPresented` flag changed (store `didSet`). `a` = 1 if
    /// the composer is now presented, else 0. An unexpected `a == 0` during a bare
    /// keyboard dismiss is the "flag toggled off" cause.
    case composerPresentedChanged = 18
    /// The store's `terminalInputText` draft changed (store `didSet`). `a` = new
    /// UTF-8 byte length; `b` = 1 if it just went to empty (a clear), else 0. A
    /// clear (`b == 1`) with no submit/sign-out nearby is the "draft cleared at the
    /// store" cause.
    case composerInputTextChanged = 19
    /// ``TerminalComposerView`` appeared (`.onAppear`). Logged independently of
    /// ``composerPresentedChanged`` so a disappear/appear pair with no flag change
    /// reveals a view-recreation bug (the flag stayed true but SwiftUI rebuilt the
    /// view).
    case composerViewAppear = 20
    /// ``TerminalComposerView`` disappeared (`.onDisappear`). A disappear without a
    /// matching ``composerPresentedChanged`` `a == 0` is a view-recreation bug, not
    /// an intentional dismiss.
    case composerViewDisappear = 21
    /// The composer's text field focus changed (`@FocusState`). `a` = 1 focused,
    /// else 0. A focus-lost (`a == 0`) while the flag stayed presented and the view
    /// stayed mounted, yet the field reads empty, isolates the residual
    /// `TextField`/`@FocusState` render-blank case.
    case composerFieldFocusChanged = 22

    // COMPOSER keyboard-toggle edge case (composer shown while the
    // textbox/keyboard is hidden). These pin which transition desyncs the
    // composer-presented flag from the keyboard/first-responder state, and they
    // land in the same `store.diagnosticLog` sink the composer events above use.

    /// `GhosttySurfaceView.setComposerActive` ran. `a` = 1 if the composer just
    /// became active, else 0. `b` = the resolved first-responder owner
    /// (``InputResponderIdentity`` raw value: which view holds first responder at
    /// the transition). `c` = 1 if the terminal input proxy is first responder,
    /// else 0. `ms` = the surface's `keyboardHeight` (points) at the transition. A
    /// trace where `a == 1` but `ms == 0` and no terminal/composer responder owns
    /// FR is the composer-up/keyboard-down desync.
    case composerActiveTransition = 23

    /// The docked bar's keyboard toggle button was tapped while the composer is
    /// presented. `a` = 1 if the terminal input proxy was first responder when
    /// tapped (so the tap would hide the keyboard), else 0. Records the exact tap
    /// that can strand the composer with the keyboard down, so round 5's "dismiss
    /// the composer too" handling can be confirmed (or the residual case named).
    case composerKeyboardToggleWhilePresented = 24

    // MARK: iOS render-grid consumer instrumentation (Round 8 frozen-render hunt)
    //
    // Lawrence hit "terminal frozen but keystrokes reach macOS": input is alive
    // (a separate RPC path) while the render-grid CONSUMER is wedged. The prior
    // rounds instrumented input/responder only, so a frozen render could not be
    // localized. These codes instrument the render-grid consumer seam — the output
    // `for await` stream liveness, the off-main `render_now` busy/skip state, and the
    // applied-frame timeline — so a single Capture&Send pinpoints whether the stream
    // stopped delivering, the render queue wedged, or frames stopped applying. They
    // ride the lock-free ``DiagnosticLog/record(_:)`` hot-path sink (no per-frame
    // string log). Decode with `scripts/decode-ios-diagnostic.py`. Tagged "RENDER:".

    /// A render-grid output chunk was applied to the libghostty surface (the main hop
    /// in `GhosttySurfaceView.processOutput`). Time-gated (≈1/s) so it is a heartbeat,
    /// not a per-byte flood. `ms` = milliseconds since the previous applied chunk, so a
    /// growing gap (or this event ceasing) localizes a stalled consumer while input
    /// still works. `a` = the chunk's byte length. RENDER: frame-apply timestamp.
    case renderFrameApplied = 25

    /// A `render_now` could not be dispatched because one was already in flight on the
    /// serial output queue (`GhosttySurfaceView.requestRender` coalesce). `a` =
    /// milliseconds the current render has been in flight so far. A long, climbing
    /// value with the screen frozen is the "render busy / snapshot skipped" wedge —
    /// the render queue is backed up while input (a separate path) still works.
    /// RENDER: render-busy / snapshot-skipped state.
    case renderBusySkipped = 26

    /// One `render_now` completed. `ms` = how long it was in flight (enqueue →
    /// main-hop completion), in milliseconds. Normal renders are a few ms; a spike with
    /// a frozen screen confirms the GPU/swap-chain `render_now` itself stalled rather
    /// than the stream drying up. RENDER: render-busy duration.
    case renderCompleted = 27

    /// A pairing attempt was short-circuited because the device had no network
    /// path (the reachability preflight failed before any connect).
    case pairUnreachable = 28
}
