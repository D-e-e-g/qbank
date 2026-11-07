import QBankDesign
import QBankKit
import SwiftUI

/// A course's Recently deleted: the pages, folders, sets and past exams she deleted in the last 30
/// days, newest first, each with Bring back. A folder brings back the sets that went with it. A page
/// went alone: its folders are in the course meanwhile, and Bring back puts them back on it.
struct RecentlyDeletedView: View {
    @State private var model: RecentlyDeletedModel
    let app: AppModel

    init(app: AppModel, courseID: String) {
        self.app = app
        _model = State(initialValue: RecentlyDeletedModel(app: app, courseID: courseID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                content
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space3)
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Recently deleted")
        .screenColumnTitle()
        .refreshable { await model.load() }
        .reloadsWithConnection(app) { await model.load() }
        .task { await model.load() }
        .onChange(of: app.deletions.revision) {
            // Deleted elsewhere, or brought back from the Undo bar.
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.needsConnection {
            OfflineBanner.deletingNeedsConnection
                .accessibilityIdentifier("deleted.needsConnection")
        }
        if let problem = model.problem {
            ProblemText(text: problem)
        }
        if let back = model.back {
            SavedText(text: back)
        }
        if let deleted = model.deleted {
            if deleted.isEmpty {
                EmptyCard(message: "Nothing deleted in the last \(deleted.undoDays) days.", systemImage: "trash")
                    .accessibilityIdentifier("deleted.empty")
            } else {
                if !deleted.examPages.isEmpty {
                    QBankListGroup(header: "Pages") {
                        ForEach(deleted.examPages) { page in
                            row(
                                .examPage(id: page.id, name: page.name),
                                title: page.name,
                                lines: [RecentlyDeletedWording.folders(page), RecentlyDeletedWording.window(deletedAt: page.deletedAt, undoUntil: page.undoUntil)],
                                systemImage: "square.stack.3d.up",
                                refusal: page.undoRefusal,
                                back: DeleteWording.back(.examPage(id: page.id, name: page.name))
                            )
                        }
                    }
                }
                if !deleted.folders.isEmpty {
                    QBankListGroup(header: "Folders") {
                        ForEach(deleted.folders) { folder in
                            row(
                                .folder(id: folder.id, name: folder.name),
                                title: folder.name,
                                lines: [RecentlyDeletedWording.sets(folder), RecentlyDeletedWording.window(deletedAt: folder.deletedAt, undoUntil: folder.undoUntil)],
                                systemImage: "folder",
                                refusal: folder.undoRefusal,
                                back: DeleteWording.back(.folder(id: folder.id, name: folder.name), setCount: folder.sets.count)
                            )
                        }
                    }
                }
                if !deleted.sets.isEmpty {
                    QBankListGroup(header: "Sets") {
                        ForEach(deleted.sets) { set in
                            row(
                                .set(id: set.id, title: set.title),
                                title: set.title,
                                lines: [RecentlyDeletedWording.set(set), RecentlyDeletedWording.window(deletedAt: set.deletedAt, undoUntil: set.undoUntil)],
                                systemImage: set.kind == .exam ? "timer" : "doc.text",
                                refusal: set.undoRefusal,
                                back: DeleteWording.back(.set(id: set.id, title: set.title))
                            )
                        }
                    }
                }
                if !deleted.exams.isEmpty {
                    QBankListGroup(header: "Exams") {
                        ForEach(deleted.exams) { exam in
                            row(
                                .exam(id: exam.id),
                                title: exam.exam.pastTitle,
                                lines: ["\(exam.exam.scoreText) fully right · \(exam.exam.pastLine)", RecentlyDeletedWording.window(deletedAt: exam.deletedAt, undoUntil: exam.undoUntil)],
                                systemImage: "timer",
                                refusal: nil,
                                back: DeleteWording.back(.exam(id: exam.id))
                            )
                        }
                    }
                }
                Text("What you delete stays here for \(deleted.undoDays) days. Bring it back, and it is as it was, with your answers.")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                    .padding(.horizontal, QBankSpacing.space5)
            }
        } else if let problem = model.loadProblem {
            LoadFailed(problem: problem) {
                Task { await model.load() }
            }
        } else {
            Loading(title: "Loading what you deleted")
        }
    }

    private func row(
        _ target: DeleteTarget, title: String, lines: [String], systemImage: String, refusal: String?, back: String
    ) -> some View {
        DeletedRow(title: title, lines: lines, systemImage: systemImage, refusal: refusal) {
            if model.bringingBack == target {
                ProgressView()
                    .frame(minWidth: 44, minHeight: 32)
            } else {
                Button("Bring back") {
                    Task { await model.bringBack(target, saying: back) }
                }
                .buttonStyle(.qbank(.secondary, size: .small))
                .disabled(refusal != nil || model.bringingBack != nil || model.needsConnection)
                .accessibilityLabel("Bring back \(title)")
                .accessibilityIdentifier("deleted.bringBack.\(title)")
            }
        }
        .accessibilityIdentifier("deleted.\(title)")
    }
}

/// Something she deleted: its name, what it held and when Undo runs out, why it cannot come back
/// now when it cannot, and Bring back at its right.
struct DeletedRow<Accessory: View>: View {
    let title: String
    let lines: [String]
    let systemImage: String
    let refusal: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.qbank(.text3))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                ForEach(lines, id: \.self) { line in
                    QBankDetailText(line)
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                }
                if let refusal {
                    Text(refusal)
                        .qbankFont(.footnote, weight: .medium)
                        .foregroundStyle(.qbank(.wrong))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            accessory
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
    }
}
