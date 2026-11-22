import QBankDesign
import QBankKit
import SwiftUI

/// New course, from Home's +: Cancel, New course in Semester 2, Done; its code and name. The
/// semester's own model adds it, and the server refuses a code the semester has, in its words.
/// Once made, `made` runs before the sheet goes down, so the course can open after it.
struct NewCourseView: View {
    @State private var model: SemesterModel
    /// The course is made and Home reads its list again before the sheet goes down.
    @State private var isOpening = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    let made: (CourseSummary) async -> Void

    private enum Field {
        case code
        case title
    }

    init(app: AppModel, catalog: Catalog?, semester: Semester, made: @escaping (CourseSummary) async -> Void) {
        _model = State(initialValue: SemesterModel(catalog: CatalogModel(app: app, catalog: catalog), id: semester.id))
        self.semester = semester
        self.made = made
    }

    var body: some View {
        EditSheet(
            title: "New course in \(semester.name)",
            confirm: "Done",
            identifier: "newCourse",
            isSaving: model.isAddingCourse || isOpening,
            hasChanges: !model.newCode.isEmpty || !model.newTitle.isEmpty,
            save: save
        ) {
            LabeledField(label: "Course code") {
                TextField("Course code", text: $model.newCode, prompt: Text("BIO 101").foregroundStyle(.qbank(.text4)))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .code)
                    .onSubmit { focus = .title }
                    .accessibilityIdentifier("newCourse.code")
            }
            LabeledField(label: "Course name") {
                TextField("Course name", text: $model.newTitle, prompt: Text("Cell Biology").foregroundStyle(.qbank(.text4)))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focus, equals: .title)
                    .onSubmit(save)
                    .accessibilityIdentifier("newCourse.title")
            }
            if let problem = model.addProblem {
                ProblemText(text: problem)
            }
            SheetHint(text: "It opens empty, with its + to import its first question file.")
        }
        .onAppear { focus = .code }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !isOpening else { return }
        focus = nil
        Task {
            guard let course = await model.addCourse() else { return }
            isOpening = true
            await made(course)
            dismiss()
        }
    }
}
