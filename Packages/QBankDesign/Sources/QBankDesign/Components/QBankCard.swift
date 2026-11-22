#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// The card surface: `surface` fill, 14pt continuous corners, a 0.5pt inset
    /// hairline and the faint light-mode card shadow. No colored edges, no gradients.
    public func qbankCardBackground(pressed: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
        return background {
            shape.fill(.qbank(pressed ? .surfacePressed : .surface))
        }
        .overlay {
            shape.strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
        .qbankElevation(.card, in: shape)
    }
}

/// A static card. For a tappable card, put the content in a `Button` with
/// `.buttonStyle(.qbankCard)`.
public struct QBankCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = QBankSpacing.space5, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .qbankCardBackground()
    }
}

/// A whole card as one button: the surface darkens one step while pressed.
/// Disabled cards are dimmed to 40%.
public struct QBankCardButtonStyle: ButtonStyle {
    private let padding: CGFloat

    public init(padding: CGFloat = QBankSpacing.space5) {
        self.padding = padding
    }

    public func makeBody(configuration: Configuration) -> some View {
        QBankCardButtonBody(configuration: configuration, padding: padding)
    }
}

private struct QBankCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let padding: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .foregroundStyle(.qbank(.text1))
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous))
            .qbankCardBackground(pressed: pressed)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(QBankMotion.press, value: pressed)
    }
}

extension ButtonStyle where Self == QBankCardButtonStyle {
    public static var qbankCard: QBankCardButtonStyle { QBankCardButtonStyle() }
}

#Preview("Cards") {
    VStack(spacing: QBankSpacing.gapStack) {
        Button {
        } label: {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NURS 406").qbankFont(.footnote, weight: .semibold).foregroundStyle(.qbank(.tint))
                    Text("Mental Health").qbankFont(.headline)
                }
                HStack(spacing: QBankSpacing.space4) {
                    Text("86 questions · 3 weeks").qbankFont(.footnote).foregroundStyle(.qbank(.text2))
                    QBankTintedLabel("12 to review", systemImage: "tray", size: .small)
                }
                QBankProgressPill(value: 0.41)
            }
        }
        .buttonStyle(.qbankCard)

        QBankCard {
            Text("A course appears here when its first question file is imported.")
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
        }
    }
    .padding(QBankSpacing.gutterPhone)
    .qbankScreenBackground()
}
#endif
