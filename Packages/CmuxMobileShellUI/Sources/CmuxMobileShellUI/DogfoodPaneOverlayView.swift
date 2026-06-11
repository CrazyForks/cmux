#if os(iOS) && DEBUG
import CmuxMobileShell
import SwiftUI

/// The floating, hideable DEV dogfood pane: a draggable "bug" pill that expands
/// into an overlay card showing the agent-pushed checklist (each item a
/// multiple-choice question), a shared freeform note, and a Capture & Send
/// button.
///
/// Hosted as a normal in-hierarchy SwiftUI `.overlay` on the app's root content
/// (see ``CMUXMobileAppView``), so SwiftUI's native hit-testing delivers the
/// pill's tap + drag with no custom window. Only the pill (collapsed) or card
/// (expanded) is hittable; the surrounding `Color.clear` backdrop disables hit
/// testing so every other touch falls through to the app beneath. This replaces
/// the old passthrough `UIWindow` whose hand-rolled `hitTest` kept returning
/// `nil` on the pill's own touches and killing both gestures.
///
/// DEV-only; not shipped, so its strings are not localized.
struct DogfoodPaneOverlayView: View {
    @Bindable var model: DogfoodFeedbackModel

    /// The pill's free-drag offset from its default top-leading anchor.
    @State private var dragOffset: CGSize = .zero
    /// Default resting position: top-left of the screen, just inside the safe
    /// area. Positive width moves right, positive height moves down. Round 6 spawns
    /// it ~30px lower (64 → 94) so it clears the connection-status pill / nav chrome
    /// at the top-left on first launch.
    @State private var accumulatedOffset: CGSize = CGSize(width: 16, height: 94)
    /// True while the reposition ``DragGesture`` is active; drives the pill's
    /// lifted scale/stroke. The `TapGesture` and `DragGesture` are independent, so
    /// this no longer gates tap-to-expand — it is purely a visual cue.
    @State private var isDragging = false
    /// Measured size of the expanded card, so its drag clamp keeps the WHOLE card
    /// on-screen (the pill clamp uses the 44pt pill size, which would strand most of
    /// the card off-screen). Falls back to a reasonable estimate before first
    /// measurement.
    @State private var cardSize: CGSize = CGSize(width: 320, height: 320)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Transparent backdrop: hit-testing off so every touch outside the
                // pill/card falls through to the app beneath this overlay. This is
                // what keeps the terminal usable while the pane floats above it; no
                // custom window `hitTest` is involved any more.
                Color.clear
                    .allowsHitTesting(false)

                if model.isExpanded {
                    expandedCard(in: proxy.size)
                        .frame(maxWidth: min(360, proxy.size.width - 24))
                        .padding(12)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                            // Measure the rendered card (including the padding) so the
                            // drag clamp keeps the whole panel on-screen.
                            cardSize = newSize
                        }
                        // The expanded panel is repositionable too (round 5): it
                        // reads the SAME `accumulatedOffset` as the pill, with a
                        // card-size-aware clamp, so dragging the card and dragging the
                        // pill move one shared anchor and stay in sync across
                        // expand/collapse. `currentOffset` re-clamps per mode, so the
                        // shared anchor self-corrects when the smaller pill returns.
                        .offset(currentCardOffset(in: proxy.size))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    pill
                        .offset(currentOffset(in: proxy.size))
                        // Two cooperating recognizers: a `DragGesture` with a real
                        // movement threshold repositions the pill, and a
                        // `TapGesture` (added simultaneously) expands the overlay.
                        // A single `DragGesture(minimumDistance: 0)` is a flaky
                        // tap/drag discriminator — its zero-translation `onEnded`
                        // tap branch fires unreliably across iOS versions, which is
                        // why a clean tap did nothing. `TapGesture` has built-in
                        // movement tolerance so it won't fire after a real drag, and
                        // it does not fight the `DragGesture` the way a `Button` did.
                        .gesture(pillDragGesture(in: proxy.size))
                        .simultaneousGesture(
                            TapGesture().onEnded { model.toggleExpanded() }
                        )
                }
            }
            .animation(.snappy(duration: 0.18), value: model.isExpanded)
        }
        .ignoresSafeArea()
    }

    // MARK: - Pill

    /// The draggable bug pill. Not a `Button`: a cooperating ``TapGesture`` (open
    /// the overlay) and ``pillDragGesture`` (reposition it) handle the two
    /// intents, which avoids the SwiftUI gotcha where a `Button` swallows the drag
    /// and the pill reads as stuck in place.
    private var pill: some View {
        Image(systemName: "ladybug.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.pillSize, height: Self.pillSize)
            .background(Circle().fill(Color.pink.opacity(0.95)))
            .overlay(Circle().stroke(.white.opacity(isDragging ? 0.9 : 0.5), lineWidth: isDragging ? 2 : 1))
            .scaleEffect(isDragging ? 1.12 : 1)
            .shadow(radius: isDragging ? 8 : 4, y: 2)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.12), value: isDragging)
            .accessibilityIdentifier("DogfoodPanePill")
            .accessibilityLabel("Dogfood feedback")
            .accessibilityAddTraits(.isButton)
    }

    /// The pill's hit-target size; also the basis for keeping it on-screen.
    private static let pillSize: CGFloat = 44
    /// Minimum on-screen inset so the pill never sits flush against an edge.
    private static let pillEdgeMargin: CGFloat = 8
    /// Finger travel (points) required before the reposition `DragGesture` claims
    /// the touch. Below this the `TapGesture` wins and expands the overlay; at or
    /// above it the pill repositions. Matches the system's own touch-slop so a
    /// clean tap never reads as a drag and vice versa.
    private static let dragThreshold: CGFloat = 8

    private func currentOffset(in size: CGSize) -> CGSize {
        clampedOffset(
            CGSize(
                width: accumulatedOffset.width + dragOffset.width,
                height: accumulatedOffset.height + dragOffset.height
            ),
            in: size,
            contentSize: CGSize(width: Self.pillSize, height: Self.pillSize)
        )
    }

    /// The expanded card's live offset, clamped with the card's measured size so
    /// the whole panel stays on-screen. Shares ``accumulatedOffset`` with the pill.
    private func currentCardOffset(in size: CGSize) -> CGSize {
        clampedOffset(
            CGSize(
                width: accumulatedOffset.width + dragOffset.width,
                height: accumulatedOffset.height + dragOffset.height
            ),
            in: size,
            contentSize: cardSize
        )
    }

    /// Clamp an offset (relative to the top-leading anchor) so the dragged content
    /// of `contentSize` stays fully within the scene. Both the pill (the only
    /// affordance that reopens the overlay) and the expanded card share this anchor,
    /// so a long drag must never strand either off-screen. Positive width moves
    /// right, positive height moves down.
    private func clampedOffset(_ offset: CGSize, in size: CGSize, contentSize: CGSize) -> CGSize {
        let maxWidth = max(Self.pillEdgeMargin, size.width - contentSize.width - Self.pillEdgeMargin)
        let maxHeight = max(Self.pillEdgeMargin, size.height - contentSize.height - Self.pillEdgeMargin)
        return CGSize(
            width: min(maxWidth, max(Self.pillEdgeMargin, offset.width)),
            height: min(maxHeight, max(Self.pillEdgeMargin, offset.height))
        )
    }

    /// The reposition gesture. A real ``dragThreshold`` of movement is required
    /// before it claims the touch, so a clean tap is left entirely to the
    /// `TapGesture` (no zero-translation tap branch here to misfire). Live
    /// translation is tracked in ``dragOffset`` and persisted (clamped on-screen)
    /// on release so the pill can never be stranded off-screen.
    private func pillDragGesture(in size: CGSize) -> some Gesture {
        repositionGesture(in: size, contentSize: CGSize(width: Self.pillSize, height: Self.pillSize))
    }

    /// Reposition gesture for the expanded card, dragged by its header. Shares the
    /// pill's ``accumulatedOffset`` so the two stay in sync, and clamps with the
    /// card's measured size so the whole panel stays on-screen.
    private func cardDragGesture(in size: CGSize) -> some Gesture {
        repositionGesture(in: size, contentSize: cardSize)
    }

    /// Shared reposition gesture used by both the pill and the expanded card. A real
    /// ``dragThreshold`` of movement is required before it claims the touch, so a
    /// clean tap is left to the `TapGesture`/`Button` (no zero-translation tap branch
    /// here to misfire). Live translation is tracked in ``dragOffset`` and persisted
    /// (clamped on-screen for `contentSize`) into the shared ``accumulatedOffset`` on
    /// release.
    private func repositionGesture(in size: CGSize, contentSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                accumulatedOffset = clampedOffset(
                    CGSize(
                        width: accumulatedOffset.width + value.translation.width,
                        height: accumulatedOffset.height + value.translation.height
                    ),
                    in: size,
                    contentSize: contentSize
                )
                dragOffset = .zero
                isDragging = false
            }
    }

    // MARK: - Expanded card

    private func expandedCard(in sceneSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(in: sceneSize)
            // Value-snapshot section so a note keystroke does not invalidate the
            // checklist rows (snapshot-boundary rule).
            DogfoodChecklistSection(
                items: model.checklist.items,
                selections: model.selections,
                select: { itemID, choice in model.selectAnswer(itemID: itemID, choice: choice) }
            )
            noteSection
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func header(in sceneSize: CGSize) -> some View {
        HStack(spacing: 8) {
            // Grab handle: dragging the header (the title region) repositions the
            // whole panel, sharing the pill's anchor. A `contentShape` makes the
            // title + leading area the draggable surface; the close button keeps its
            // own tap. The drag has a movement threshold so a tap on the title is
            // not swallowed.
            Image(systemName: "line.3.horizontal")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Label(model.checklist.title ?? "Dogfood", systemImage: "ladybug.fill")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                model.toggleExpanded()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("DogfoodPaneCollapse")
        }
        // Make the whole header strip (minus the close button's own hit area) the
        // drag handle for repositioning the expanded panel.
        .contentShape(Rectangle())
        .gesture(cardDragGesture(in: sceneSize))
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $model.note)
                .font(.callout)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                )
                .accessibilityIdentifier("DogfoodPaneNote")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let succeeded = model.lastSubmitSucceeded {
                Label(
                    succeeded ? "Sent" : "Failed",
                    systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(succeeded ? Color.green : Color.orange)
            }
            Spacer()
            Button {
                Task { await model.captureAndSend() }
            } label: {
                HStack(spacing: 6) {
                    if model.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.isSubmitting ? "Sending…" : "Capture & Send")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmitting)
            .accessibilityIdentifier("DogfoodPaneCaptureSend")
        }
    }
}
#endif
