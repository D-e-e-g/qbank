import QBankDesign
import QBankKit
import SwiftUI

/// The screen over the app for the bank QBank Cloud already holds: reading it, then saying what it
/// holds and what only this iPhone has before the person decides whether QBank uses it, then offering
/// this iPhone's own sets to it as new sets. Nothing switches and nothing is added but on a tap.
struct CloudAdoptView: View {
    let app: AppModel

    private var adopt: CloudAdoptModel { app.cloudAdopt }

    var body: some View {
        CloudPage {
            switch adopt.phase {
            case .idle, .looking:
                looking
            case .found(let found):
                foundView(found)
            case .adopted:
                adopted
            case .offering(let sets):
                offering(sets)
            case .adding(let done, let total):
                adding(done, of: total)
            case .added(let count):
                added(count)
            case .failed(let problem, let retry):
                failed(problem, retry: retry)
            case .addFailed(let problem, let allAdded):
                addFailed(problem, allAdded: allAdded)
            }
        }
    }

    // MARK: Looking

    private var looking: some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "icloud", tone: .tint)
            CloudHeading(CloudAdoptWording.lookingTitle, id: "cloudAdopt.looking")
            CloudLead(CloudAdoptWording.lookingNote)
            ProgressView()
                .padding(.top, QBankSpacing.space3)
        }
    }

    // MARK: Found

    private func foundView(_ found: CloudAdoptModel.Found) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "icloud", tone: .tint)
            CloudHeading(CloudAdoptWording.foundTitle, id: "cloudAdopt.found")
            CloudLead(CloudAdoptWording.foundBody, id: "cloudAdopt.body")
            CloudCounts(summary: found.summary, header: "In QBank Cloud", prefix: "cloudAdopt")
            CloudNote(text: CloudAdoptWording.onlyHere(found.onlyOnPhone.count), systemImage: "iphone", id: "cloudAdopt.onlyHere")
            CloudNote(text: CloudAdoptWording.safetyCopy, systemImage: "lock.iphone", id: "cloudAdopt.safetyCopy")
            VStack(spacing: QBankSpacing.space2) {
                Button(CloudAdoptWording.use) { adopt.use() }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudAdopt.use")
                Button(CloudAdoptWording.notNow) { adopt.close() }
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudAdopt.later")
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudAdoptWording.foundTitle).post()
        }
    }

    // MARK: Adopted

    private var adopted: some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "checkmark.icloud", tone: .correct)
            CloudHeading(CloudAdoptWording.adoptedTitle, id: "cloudAdopt.adopted")
            CloudLead(CloudAdoptWording.adoptedBody, id: "cloudAdopt.safetyCopy")
            doneButton
        }
    }

    // MARK: Offering

    private func offering(_ sets: [BankOffer.PhoneSet]) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "plus.square.on.square", tone: .tint)
            CloudHeading(CloudAdoptWording.offeringTitle(sets.count, into: adopt.into), id: "cloudAdopt.offering")
            CloudLead(CloudAdoptWording.offeringBody(sets.count, into: adopt.into), id: "cloudAdopt.offeringBody")
            QBankListGroup {
                ForEach(sets) { set in
                    QBankListRow(set.title, detail: CloudAdoptWording.place(set.place), systemImage: "rectangle.stack")
                        .accessibilityIdentifier("cloudAdopt.set.\(set.title)")
                }
            }
            VStack(spacing: QBankSpacing.space2) {
                Button(CloudAdoptWording.add(sets.count, into: adopt.into)) {
                    Task { await adopt.add() }
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("cloudAdopt.add")
                Button(CloudAdoptWording.notNow) { adopt.close() }
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudAdopt.later")
            }
            .padding(.top, QBankSpacing.space3)
        }
    }

    // MARK: Adding

    private func adding(_ done: Int, of total: Int) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: adopt.into == .cloud ? "icloud.and.arrow.up" : "plus.square.on.square", tone: .tint)
            CloudHeading(CloudAdoptWording.addingTitle(total, into: adopt.into), id: "cloudAdopt.adding")
            CloudLead(CloudAdoptWording.adding(done, of: total), id: "cloudAdopt.progress")
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityHidden(true)
        }
    }

    // MARK: Added

    private func added(_ count: Int) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: adopt.into == .cloud ? "checkmark.icloud" : "checkmark.circle", tone: .correct)
            CloudHeading(CloudAdoptWording.addedTitle(count, into: adopt.into), id: "cloudAdopt.added")
            CloudLead(CloudAdoptWording.addedBody(count, into: adopt.into), id: "cloudAdopt.addedBody")
            doneButton
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudAdoptWording.addedTitle(count, into: adopt.into)).post()
        }
    }

    // MARK: Failed

    private func failed(_ problem: String, retry: CloudAdoptModel.Retry?) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "exclamationmark.icloud", tone: .partial)
            CloudHeading(CloudAdoptWording.failedTitle, id: "cloudAdopt.failed")
            CloudProblemCard(problem: problem, unchanged: CloudMoveWording.unchanged, prefix: "cloudAdopt")
            VStack(spacing: QBankSpacing.space2) {
                if let retry {
                    Button(CloudAdoptWording.tryAgain) {
                        Task { await adopt.retry(retry) }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudAdopt.retry")
                    Button(CloudAdoptWording.notNow) { adopt.close() }
                        .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudAdopt.later")
                } else {
                    Button(CloudAdoptWording.ok) { adopt.close() }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudAdopt.later")
                }
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(problem).post()
        }
    }

    // MARK: Adding failed

    private func addFailed(_ problem: String, allAdded: Bool) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "exclamationmark.icloud", tone: .partial)
            CloudHeading(allAdded ? CloudAdoptWording.addedNotNotedTitle : CloudAdoptWording.addFailedTitle, id: "cloudAdopt.failed")
            CloudProblemCard(problem: problem, unchanged: CloudAdoptWording.addUnchanged(adopt.into, allAdded: allAdded), prefix: "cloudAdopt")
            VStack(spacing: QBankSpacing.space2) {
                if allAdded {
                    Button(CloudAdoptWording.ok) { adopt.close() }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudAdopt.later")
                } else {
                    Button(CloudAdoptWording.tryAgain) {
                        Task { await adopt.add() }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudAdopt.retry")
                    Button(CloudAdoptWording.notNow) { adopt.close() }
                        .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudAdopt.later")
                }
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(problem).post()
        }
    }

    private var doneButton: some View {
        Button(CloudAdoptWording.done) { adopt.close() }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .accessibilityIdentifier("cloudAdopt.done")
            .padding(.top, QBankSpacing.space3)
    }
}
