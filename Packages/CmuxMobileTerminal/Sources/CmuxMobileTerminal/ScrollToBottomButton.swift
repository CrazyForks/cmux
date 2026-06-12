import UIKit

/// A small circular floating button that jumps the terminal to the live bottom.
///
/// Shown over the bottom-right of the terminal, floating just above the docked
/// accessory toolbar (and the composer band / keyboard when they are up), only
/// while the surface is scrolled up into scrollback. Tapping it asks the surface
/// to scroll all the way down; the button then self-hides when the next
/// render-grid frame reports the viewport is back at the bottom.
///
/// Visuals mirror the accessory toolbar buttons: Liquid Glass on iOS 26, a
/// translucent dark circle on earlier OSes, with a `chevron.down` glyph. The
/// caller owns positioning (it rides the dock geometry) and the show/hide
/// transition; this view is purely the styled, tappable affordance.
final class ScrollToBottomButton: UIButton {
    /// Diameter of the circular button in points. Sized to read as a peer of the
    /// accessory toolbar's glyph buttons without crowding the terminal.
    static let diameter: CGFloat = 40

    /// Invoked when the button is tapped. The owner forwards this to the surface
    /// delegate so the Mac scrolls its real surface to the bottom.
    var onTap: (() -> Void)?

    /// Creates the styled button. The tap handler is wired to ``onTap``.
    init() {
        super.init(frame: .zero)
        configureStyle()
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityLabel = String(
            localized: "terminal.scrollToBottom.accessibility",
            defaultValue: "Scroll to bottom"
        )
        // The lifted glass must not be clipped by the button's own circular
        // bounds, matching the no-clip the bottom chrome uses for its controls.
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.diameter, height: Self.diameter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the pre-26 fallback fill a true circle as bounds settle. On iOS 26
        // the glass capsule corner is driven by the configuration, so this only
        // matters for the layer-level fallback background.
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
    }

    @objc private func handleTap() {
        onTap?()
    }

    /// Apply the Liquid-Glass (iOS 26) or translucent-circle (earlier) styling
    /// with a down-chevron glyph, consistent with the accessory toolbar buttons.
    private func configureStyle() {
        let symbol = UIImage(systemName: "chevron.down")
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if #available(iOS 26.0, *) {
            var config: UIButton.Configuration = .glass()
            config.image = symbol
            config.preferredSymbolConfigurationForImage = symbolConfig
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            configuration = config
        } else {
            var config = UIButton.Configuration.plain()
            config.image = symbol
            config.preferredSymbolConfigurationForImage = symbolConfig
            config.baseForegroundColor = .white
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            background.cornerRadius = Self.diameter / 2
            config.background = background
            configuration = config
            // Match the toolbar's subtle hairline so the circle reads on a light
            // terminal background.
            layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            layer.borderWidth = 1
        }
    }
}
