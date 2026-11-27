import QBankDesign
import SwiftUI

/// Settings' Cloud, for a store account: whether QBank Cloud is on, as QBank's server says, the plans
/// sheet, and, while Cloud is on and the bank is still on this phone, moving it to QBank Cloud, or
/// using the bank QBank Cloud holds already. Once QBank uses QBank Cloud's bank, it offers this phone's
/// own sets to it; once Cloud has ended, it brings the bank back when an earlier try did not, or brings
/// QBank's bank to a new phone the person said not now to. Shown
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
            if app.cloudAdopt.isOffered {
                Button {
                    Task { await app.cloudAdopt.ask() }
                } label: {
                    QBankListRow(CloudAdoptWording.useCloudBank, detail: CloudAdoptWording.useCloudBankDetail, systemImage: "icloud")
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("settings.useCloudBank")
            }
            if app.cloudAdopt.offersSets {
                Button {
                    app.cloudAdopt.offerSets()
                } label: {
                    QBankListRow(
                        CloudAdoptWording.addSets(app.cloudAdopt.into), detail: CloudAdoptWording.addSetsDetail(app.cloudAdopt.offeredCount, into: app.cloudAdopt.into),
                        systemImage: "plus.square.on.square")
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("settings.addPhoneSets")
            }
            if app.cloudReturn.offersServerBank {
                Button {
                    app.cloudReturn.offerServerBank()
                } label: {
                    QBankListRow(CloudReturnWording.bringHere, detail: CloudReturnWording.bringHereDetail, systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("settings.bringBankHere")
            }
            if app.cloudReturn.isOffered {
                Button {
                    Task { await app.cloudReturn.start() }
                } label: {
                    QBankListRow(CloudReturnWording.bringBack, detail: CloudReturnWording.stillInCloud, systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("settings.bringBankBack")
            }
        }
        .sheet(isPresented: $showsPlans, onDismiss: plansClosed) {
            CloudPlansView(app: app)
        }
        .task {
            app.cloudAdopt.refreshOffer()
            await app.cloud.refresh()
        }
    }

    private func plansClosed() {
        Task { await app.cloudMove.plansClosed() }
    }
}
