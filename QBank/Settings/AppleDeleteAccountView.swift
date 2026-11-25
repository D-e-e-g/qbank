import QBankDesign
import StoreKit
import SwiftUI

/// Delete account for a store account, free or Cloud: what goes, in plain words, that a subscription
/// goes on until it is cancelled, with Manage subscription, and the delete, which Apple confirms
/// first. The same screen, on its own, finishes a delete that stopped once this phone's copy was
/// erased.
struct AppleDeleteAccountView: View {
    @State private var model: AppleDeleteAccountModel
    @State private var managesSubscription = false

    init(app: AppModel) {
        _model = State(initialValue: AppleDeleteAccountModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                Text(model.message)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                    .accessibilityIdentifier("deleteAccount.message")
                subscription
                if let problem = model.problem {
                    ProblemText(text: problem)
                }
                VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                    Button(action: delete) {
                        if model.isDeleting {
                            ProgressView()
                                .tint(QBankColor(.wrong))
                                .accessibilityLabel("Deleting")
                        } else {
                            Text("Delete account")
                        }
                    }
                    .buttonStyle(.qbank(.destructive, size: .large, fullWidth: true))
                    .disabled(model.isDeleting)
                    .accessibilityIdentifier("deleteAccount.delete")
                    Text(AccountDeletionWording.appleConfirms)
                        // A sentence, so not the footnote's mono face, which is for labels and numbers.
                        .qbankFont(.footnote, design: .default)
                        .foregroundStyle(.qbank(.text3))
                        .accessibilityIdentifier("deleteAccount.apple")
                }
                .padding(.top, 2)
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space3)
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Delete account")
        .screenColumnTitle()
        .manageSubscriptionsSheet(isPresented: $managesSubscription)
    }

    /// A subscription is billed by Apple, so deleting the account does not end it: said before the
    /// delete, with the way to cancel it.
    private var subscription: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            Text(AccountDeletionWording.subscription)
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deleteAccount.subscription")
            Button("Manage subscription") {
                managesSubscription = true
            }
            .buttonStyle(.qbank(.secondary, size: .small))
            .accessibilityIdentifier("deleteAccount.manageSubscription")
        }
    }

    private func delete() {
        Task { await model.delete(over: nil) }
    }
}
