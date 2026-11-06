import QBankDesign
import SwiftUI

extension View {
    /// Asks before something that cannot be undone, as the web's ConfirmSheet asks: a sheet from
    /// the bottom with the question, what happens, the action, and a harmless way out, both always
    /// visible. Swiping it down is the same as the harmless way out.
    func confirmSheet(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirm: String,
        isDestructive: Bool = true,
        cancel: String = "Cancel",
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            ConfirmSheet(
                title: title,
                message: message,
                confirm: confirm,
                isDestructive: isDestructive,
                cancel: cancel,
                identifier: identifier
            ) { confirmed in
                isPresented.wrappedValue = false
                if confirmed { action() }
            }
        }
    }
}

/// The sheet `confirmSheet` shows. Shown by itself, it can also stay open while its action runs,
/// with a problem line when the action fails, as a delete does.
struct ConfirmSheet: View {
    let title: String
    let message: String
    /// The most the message takes before it scrolls, for one that can run long, or nil for no limit.
    var messageMaxHeight: CGFloat?
    let confirm: String
    var isDestructive = true
    var cancel = "Cancel"
    let identifier: String
    /// True while the action runs: the buttons wait, and the sheet stays.
    var isBusy = false
    /// True while what the message says is still being read: a spinner stands in for it.
    var isLoading = false
    /// False while the action cannot be done, such as a delete the server refuses for now. The way
    /// out stays.
    var canConfirm = true
    var problem: String?
    let answer: (Bool) -> Void
    @State private var height: CGFloat = 280
    @State private var messageHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: QBankSpacing.space3) {
            Text(title)
                .qbankFont(.headline)
                .foregroundStyle(.qbank(.text1))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("\(identifier).title")
            if isLoading {
                ProgressView()
                    .frame(minHeight: 44)
                    .padding(.bottom, QBankSpacing.space3)
            } else if let messageMaxHeight {
                ScrollView {
                    messageText
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { messageHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(messageHeight, messageMaxHeight))
                .padding(.bottom, QBankSpacing.space3)
            } else {
                messageText
                    .padding(.bottom, QBankSpacing.space3)
            }
            if let problem {
                ProblemText(text: problem)
                    .padding(.bottom, QBankSpacing.space2)
            }
            Button {
                answer(true)
            } label: {
                if isBusy {
                    ProgressView()
                        .tint(QBankColor(.textOnTint))
                        .accessibilityLabel(confirm)
                } else {
                    Text(confirm)
                }
            }
            .buttonStyle(.qbank(isDestructive ? .destructive : .primary, size: .large, fullWidth: true))
            .disabled(isLoading || !canConfirm)
            .accessibilityIdentifier("\(identifier).confirm")
            Button(cancel) { answer(false) }
                .buttonStyle(.qbank(.quiet, size: .large, fullWidth: true))
                .accessibilityIdentifier("\(identifier).cancel")
        }
        .disabled(isBusy)
        .interactiveDismissDisabled(isBusy)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, QBankSpacing.gutterPhone)
        .padding(.top, 28)
        .padding(.bottom, QBankSpacing.space4)
        .frame(maxWidth: QBankLayout.contentMax)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationBackground(.qbank(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var messageText: some View {
        Text(message)
            .qbankFont(.subheadline)
            .foregroundStyle(.qbank(.text2))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("\(identifier).message")
    }
}
