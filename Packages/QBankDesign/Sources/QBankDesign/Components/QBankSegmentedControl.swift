#if canImport(SwiftUI)
import SwiftUI

/// A row of equal segments with one chosen, drawn as the web's `.segments`: a sunken
/// track with a hairline edge, and the chosen segment raised on it in semibold primary
/// text. Settings uses it for Look (Match device, Light, Dark), Review for its four
/// filters. A label stays on one line, shrinking a little before it would wrap. Each
/// segment is a 44pt tap target; VoiceOver reads the chosen one as selected.
public struct QBankSegmentedControl<Value: Hashable>: View {
    public struct Option {
        public let value: Value
        public let label: String

        public init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    private let label: String
    @Binding private var selection: Value
    private let options: [Option]
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter label: What VoiceOver calls the whole control, such as "Look".
    public init(_ label: String, selection: Binding<Value>, options: [Option]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.qbank(.surfaceSunken))
                .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button {
            guard !isSelected else { return }
            withAnimation(reduceMotion ? nil : QBankMotion.select) {
                selection = option.value
            }
        } label: {
            Text(option.label)
                .qbankFont(.subheadline, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(.qbank(isSelected ? .text1 : .text2))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, QBankSpacing.space2)
                .padding(.vertical, QBankSpacing.space2)
                .frame(maxWidth: .infinity, minHeight: QBankSpacing.rowMin)
                .background {
                    if isSelected {
                        shape
                            .fill(.qbank(.surfaceRaised))
                            .qbankElevation(.raised, in: shape)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(QBankSegmentButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// No press effect beyond a slight fade: the raised thumb is the feedback.
private struct QBankSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(QBankMotion.press, value: configuration.isPressed)
    }
}

#Preview("Segmented control") {
    @Previewable @State var look = "auto"
    VStack(alignment: .leading, spacing: QBankSpacing.gapSection) {
        QBankListGroup(header: "Look", footer: "Match device follows this device's light or dark setting.") {
            QBankSegmentedControl(
                "Look", selection: $look,
                options: [
                    .init("auto", "Match device"),
                    .init("light", "Light"),
                    .init("dark", "Dark"),
                ]
            )
            .padding(QBankSpacing.space3)
        }
    }
    .padding(QBankSpacing.gutterPhone)
    .frame(maxHeight: .infinity, alignment: .top)
    .qbankScreenBackground()
}
#endif
