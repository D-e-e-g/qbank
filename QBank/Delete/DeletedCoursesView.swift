import QBankDesign
import QBankKit
import SwiftUI

/// Home's Recently deleted, from its last row: the courses and study topics she deleted in the last
/// 30 days, under Courses and Study topics, newest first, each with Bring back. A course comes back
/// whole, in its semester or her topics: its folders, pages, sets, past exams and her answers. The
/// owner's view reads it without Bring back.
struct DeletedCoursesView: View {
    @State private var model: DeletedCoursesModel
    let app: AppModel

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: DeletedCoursesModel(app: app))
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
            // Deleted from Home, or brought back from the Undo bar.
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
            if deleted.courses.isEmpty {
                EmptyCard(message: "No course or study topic was deleted in the last \(deleted.undoDays) days.", systemImage: "trash")
                    .accessibilityIdentifier("deleted.empty")
            } else {
                if !model.courses.isEmpty {
                    QBankListGroup(header: "Courses") {
                        ForEach(model.courses) { course in
                            row(course, systemImage: "book.closed")
                        }
                    }
                }
                if !model.topics.isEmpty {
                    QBankListGroup(header: "Study topics") {
                        ForEach(model.topics) { topic in
                            row(topic, systemImage: "text.book.closed")
                        }
                    }
                }
                Text("Each one can be brought back for \(deleted.undoDays) days after it was deleted, with its folders, sets and your answers. After that it stays deleted.")
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

    private func row(_ course: DeletedCourse, systemImage: String) -> some View {
        let name = Wording.name(course)
        return DeletedRow(
            title: name,
            lines: DeletedCoursesWording.held(course) + [RecentlyDeletedWording.window(deletedAt: course.deletedAt, undoUntil: course.undoUntil)],
            systemImage: systemImage,
            refusal: course.undoRefusal
        ) {
            if model.bringingBack == .course(id: course.id, name: name) {
                ProgressView()
                    .frame(minWidth: 44, minHeight: 32)
            } else {
                Button("Bring back") {
                    Task { await model.bringBack(course) }
                }
                .buttonStyle(.qbank(.secondary, size: .small))
                .disabled(course.undoRefusal != nil || model.bringingBack != nil || model.needsConnection)
                .accessibilityLabel("Bring back \(name)")
                .accessibilityIdentifier("deleted.bringBack.\(name)")
            }
        }
        .accessibilityIdentifier("deleted.\(name)")
    }
}

/// Home's Recently deleted, on Home's navigation stack.
struct DeletedCoursesRoute: Hashable {}
