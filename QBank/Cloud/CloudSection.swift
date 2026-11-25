import QBankDesign
import SwiftUI

/// Settings' Cloud, for a store account: whether QBank Cloud is on, as QBank's server says, and the
/// plans sheet. Shown only where `CloudModel.isOffered(to:)`.
struct CloudSection: View {
    let app: AppModel
    @State private var showsPlans = false

    var body: some View {
        let status = app.cloud.status
        QBankListGroup(header: "Cloud") {
            Button {
                showsPlans = true
            } label: {
                QBankListRow(
                    CloudWording.title,
                    detail: CloudWording.settingsDetail(status),
                    value: CloudWording.settingsValue(status),
                    systemImage: "icloud",
                    showsChevron: true
                )
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("settings.cloud")
        }
        .sheet(isPresented: $showsPlans) {
            CloudPlansView(app: app)
        }
        .task {
            await app.cloud.refresh()
        }
    }
}
