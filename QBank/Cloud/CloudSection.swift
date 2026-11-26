import QBankDesign
import SwiftUI

/// Settings' Cloud, for a store account: whether QBank Cloud is on, as QBank's server says, the plans
/// sheet, and, while Cloud is on and the bank is still on this phone, moving it to QBank Cloud. Shown
/// only where `CloudModel.isOffered(to:)`. A move a purchase or Restore in the sheet made due starts
/// once the sheet has closed, so the move's screen never opens over it.
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
            if app.cloudMove.isOffered {
                Button {
                    Task { await app.cloudMove.start() }
                } label: {
                    QBankListRow(CloudMoveWording.move, detail: CloudMoveWording.stillOnPhone, systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("settings.moveToCloud")
            }
        }
        .sheet(isPresented: $showsPlans, onDismiss: plansClosed) {
            CloudPlansView(app: app)
        }
        .task {
            await app.cloud.refresh()
        }
    }

    private func plansClosed() {
        Task { await app.cloudMove.plansClosed() }
    }
}
