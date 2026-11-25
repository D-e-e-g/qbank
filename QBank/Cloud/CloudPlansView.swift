import QBankDesign
import QBankKit
import SwiftUI
import UIKit

/// The plans sheet: what QBank Cloud is, each plan's name, period and price as the App Store gives
/// them, the sentence on renewing, the privacy policy and the terms of use, and Restore purchases.
/// Once QBank's server says Cloud is on, the sheet says so, with Manage subscription, in place of the
/// plans.
struct CloudPlansView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The policy or terms page open over the sheet, if one is.
    @State private var openPage: URL?

    private var cloud: CloudModel { app.cloud }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: QBankSpacing.space5) {
                    Text(CloudWording.lead)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud.lead")
                    if let status = cloud.status, status.active {
                        active(status)
                    } else {
                        plans
                    }
                    if let notice = cloud.notice {
                        SavedText(text: notice)
                    }
                    if let problem = cloud.problem {
                        ProblemText(text: problem)
                    }
                    Text(CloudWording.autoRenew)
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud.autoRenew")
                    QBankListGroup {
                        link(CloudWording.privacyPolicy, LegalLinks.privacyPolicy, id: "cloud.privacy")
                        link(CloudWording.termsOfUse, LegalLinks.termsOfUse, id: "cloud.terms")
                    }
                    QBankListGroup {
                        Button(action: restore) {
                            QBankListRow(CloudWording.restore, systemImage: "arrow.clockwise", showsChevron: false) {
                                if cloud.isRestoring {
                                    ProgressView()
                                }
                            }
                        }
                        .buttonStyle(.qbankRow)
                        .disabled(cloud.isRestoring || cloud.buying != nil)
                        .accessibilityIdentifier("cloud.restore")
                    }
                }
                .screenColumn()
                .padding(.top, QBankSpacing.space3)
                .padding(.bottom, QBankSpacing.space7)
            }
            .qbankScreenBackground()
            .navigationTitle(CloudWording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("cloud.done")
                }
            }
        }
        .webPageSheet($openPage)
        .task { await cloud.loadPlans() }
    }

    /// Each plan the App Store sells, while they load, or why they could not.
    @ViewBuilder private var plans: some View {
        if let plans = cloud.plans {
            ForEach(plans) { plan in
                card(plan)
            }
        } else if let problem = cloud.plansProblem {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                ProblemText(text: problem)
                Button("Try again") {
                    Task { await cloud.loadPlans() }
                }
                .buttonStyle(.qbank(.secondary, size: .small))
                .accessibilityIdentifier("cloud.plans.retry")
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityLabel("Loading the plans")
        }
    }

    /// A plan: its name, how long one payment lasts and its price, as the App Store gives them, and
    /// Subscribe.
    private func card(_ plan: CloudPlan) -> some View {
        let key = Self.key(plan)
        return QBankCard {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                HStack(alignment: .firstTextBaseline, spacing: QBankSpacing.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                            .qbankFont(.headline)
                            .foregroundStyle(.qbank(.text1))
                            .accessibilityIdentifier("cloud.plan.\(key).name")
                        Text(CloudWording.periodLine(plan.period))
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text2))
                            .accessibilityIdentifier("cloud.plan.\(key).period")
                    }
                    Spacer(minLength: QBankSpacing.space3)
                    Text(plan.price)
                        .qbankFont(.headline)
                        .foregroundStyle(.qbank(.text1))
                        .fixedSize()
                        .accessibilityIdentifier("cloud.plan.\(key).price")
                }
                Button {
                    buy(plan)
                } label: {
                    if cloud.buying == plan.id {
                        ProgressView()
                            .tint(QBankColor(.textOnTint))
                            .accessibilityLabel("Subscribing")
                    } else {
                        Text(CloudWording.subscribe)
                    }
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(cloud.buying != nil || cloud.isRestoring)
                .accessibilityLabel("\(CloudWording.subscribe), \(plan.name), \(plan.price) for \(plan.period.text)")
                .accessibilityIdentifier("cloud.plan.\(key).subscribe")
            }
        }
    }

    /// Cloud is on, as the server says: until when it is paid, and Apple's Manage subscription.
    private func active(_ status: CloudStatus) -> some View {
        QBankCard {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(CloudWording.activeTitle)
                            .foregroundStyle(.qbank(.text1))
                    } icon: {
                        Image(systemName: "checkmark.icloud")
                            .foregroundStyle(.qbank(.correct))
                    }
                    .qbankFont(.headline)
                    .accessibilityIdentifier("cloud.active")
                    if let expiresAt = status.expiresAt {
                        Text(CloudWording.paidUntil(expiresAt))
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text2))
                            .accessibilityIdentifier("cloud.paidUntil")
                    }
                }
                Button(CloudWording.manage, action: manage)
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloud.manage")
            }
        }
    }

    private func link(_ title: String, _ url: URL, id: String) -> some View {
        Button {
            openPage = url
        } label: {
            QBankListRow(title, systemImage: "arrow.up.right", showsChevron: false)
        }
        .buttonStyle(.qbankRow)
        .accessibilityIdentifier(id)
    }

    private func buy(_ plan: CloudPlan) {
        Task { await cloud.buy(plan, in: Self.scene) }
    }

    private func restore() {
        Task { await cloud.restore() }
    }

    private func manage() {
        Task { await cloud.manage(in: Self.scene) }
    }

    /// The last part of a plan's product id, "monthly" or "yearly", which names its controls.
    static func key(_ plan: CloudPlan) -> String {
        plan.id.split(separator: ".").last.map(String.init) ?? plan.id
    }

    /// The window scene in front, which Apple's purchase and subscription sheets open over: the one
    /// holding the key window, on an iPad with several.
    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return scenes.first { $0.keyWindow != nil } ?? scenes.first
    }
}
