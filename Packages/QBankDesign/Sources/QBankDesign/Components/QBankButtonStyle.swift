#if canImport(SwiftUI)
import SwiftUI

/// The QBank button. Primary is the one main action on a screen (Check answer,
/// Import); secondary, quiet and plain are for the rest. Labels are sentence case,
/// verb first. Pressed: the fill darkens one step and the button scales to 0.98.
/// Disabled: grey, a sunken fill with a muted label, so it reads as unavailable and
/// its words stay legible in light and dark. (Fading the whole button, as the web
/// does, leaves the primary label unreadable in dark mode.) A small plain button has no
/// fill at rest, so disabled it takes the sunken one: a muted label alone reads as a
/// working button.
public struct QBankButtonStyle: ButtonStyle {
    public enum Variant: String, CaseIterable, Sendable {
        /// Tint fill, on-tint text.
        case primary
        /// Soft tint fill, tint text.
        case secondary
        /// Sunken neutral fill, primary text.
        case quiet
        /// No fill, tint text.
        case plain
        /// Soft brick fill, brick text.
        case destructive
    }

    public enum Size: String, CaseIterable, Sendable {
        /// 50pt tall, headline text. The pinned footer action.
        case large
        /// 44pt tall, semibold callout text.
        case medium
        /// 32pt tall (with a 44pt tap target), semibold subheadline text. Inline actions in rows (Restore).
        case small

        public var minHeight: CGFloat {
            switch self {
            case .large: 50
            case .medium: 44
            case .small: 32
            }
        }

        public var horizontalPadding: CGFloat {
            switch self {
            case .large: 20
            case .medium: 16
            case .small: 12
            }
        }

        /// Extra tap area above and below, so every size keeps a 44pt target.
        public var tapSlop: CGFloat {
            max(0, (QBankSpacing.rowMin - minHeight) / 2)
        }

        /// Lets the button grow with large text instead of truncating its label.
        var verticalPadding: CGFloat {
            switch self {
            case .large: 10
            case .medium: 8
            case .small: 6
            }
        }

        public var cornerRadius: CGFloat {
            switch self {
            case .large, .medium: QBankRadius.sm
            case .small: 8
            }
        }

        var textStyle: QBankTextStyle {
            switch self {
            case .large: .headline
            case .medium: .callout
            case .small: .subheadline
            }
        }
    }

    public let variant: Variant
    public let size: Size
    public let fullWidth: Bool

    public init(_ variant: Variant = .primary, size: Size = .medium, fullWidth: Bool = false) {
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        QBankButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == QBankButtonStyle {
    /// `.buttonStyle(.qbank(.primary, size: .large, fullWidth: true))`
    public static func qbank(
        _ variant: QBankButtonStyle.Variant = .primary,
        size: QBankButtonStyle.Size = .medium,
        fullWidth: Bool = false
    ) -> QBankButtonStyle {
        QBankButtonStyle(variant, size: size, fullWidth: fullWidth)
    }
}

private struct QBankButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: QBankButtonStyle.Variant
    let size: QBankButtonStyle.Size
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .labelStyle(QBankButtonLabelStyle())
            .qbankFont(size.textStyle, weight: .semibold)
            .multilineTextAlignment(.center)
            .foregroundStyle(.qbank(isEnabled ? foreground : .text3))
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.minHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                (pressed ? pressedFill : currentFill).map { AnyShapeStyle(.qbank($0)) } ?? AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            )
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .animation(QBankMotion.press, value: pressed)
            // Small buttons draw 32pt tall but keep a 44pt tap target.
            .padding(.vertical, size.tapSlop)
            .contentShape(Rectangle())
    }

    private var foreground: QBankColorToken {
        switch variant {
        case .primary: .textOnTint
        case .secondary, .plain: .tint
        case .quiet: .text1
        case .destructive: .wrong
        }
    }

    /// The fill at rest: grey when disabled, except for a plain button, which has none, unless
    /// it is small: a bare text button is too easy to take for a working one.
    private var currentFill: QBankColorToken? {
        guard !isEnabled else { return fill }
        return variant == .plain && size != .small ? nil : .surfaceSunken
    }

    /// `nil` is no fill.
    private var fill: QBankColorToken? {
        switch variant {
        case .primary: .tint
        case .secondary: .tintSoft
        case .quiet: .surfaceSunken
        case .plain: nil
        case .destructive: .wrongSoft
        }
    }

    private var pressedFill: QBankColorToken? {
        switch variant {
        case .primary: .tintPressed
        case .secondary: .tintSoftBorder
        case .quiet: .surfacePressed
        case .plain: .surfaceSunken
        case .destructive: .wrongBorder
        }
    }
}

/// Icon and title side by side with an 8pt gap, as on the web.
private struct QBankButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: QBankSpacing.space3) {
            configuration.icon
            configuration.title
        }
    }
}

#Preview("Buttons") {
    ScrollView {
        VStack(alignment: .leading, spacing: QBankSpacing.gapStack) {
            Button("Check answer") {}
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            Button("Check answer") {}
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(true)
            ForEach(QBankButtonStyle.Variant.allCases, id: \.self) { variant in
                HStack(spacing: QBankSpacing.space3) {
                    Button(variant.rawValue.capitalized) {}
                        .buttonStyle(.qbank(variant))
                    Button {
                    } label: {
                        Label("Restore", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.qbank(variant, size: .small))
                }
            }
        }
        .padding(QBankSpacing.gutterPhone)
    }
    .qbankScreenBackground()
}
#endif
