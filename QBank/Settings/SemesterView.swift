import QBankDesign
import QBankKit
import SwiftUI

/// One semester, with the web's fields: its name and dates, and archiving it by hand. Home's +
/// adds a course to it, and holding a course on Home moves it to another.
struct SemesterView: View {
    @State private var model: SemesterModel
    @FocusState private var focus: Field?

    private enum Field {
        case name
    }

    init(catalog: CatalogModel, id: String) {
        _model = State(initialValue: SemesterModel(catalog: catalog, id: id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space7) {
                details
                archive
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space3)
            .padding(.bottom, QBankSpacing.space7)
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle(model.semester?.name ?? "Semester")
        .screenColumnTitle()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            LabeledField(label: "Name") {
                TextField("Name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("semester.name")
            }
            QBankListGroup {
                DayRow(title: "Starts", day: $model.startsOn, identifier: "semester.starts")
                DayRow(title: "Ends", day: $model.endsOn, identifier: "semester.ends")
            }
            if let problem = model.saveProblem {
                ProblemText(text: problem)
            }
            if model.isSaved {
                SavedText(text: "Saved.")
            }
            Button {
                focus = nil
                Task { await model.save() }
            } label: {
                if model.isSaving {
                    ProgressView().accessibilityLabel("Saving")
                } else {
                    Text("Save \(model.semester?.name ?? "semester")")
                }
            }
            .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
            .disabled(model.isSaving)
            .accessibilityIdentifier("semester.save")
        }
    }

    /// By hand only: nothing archives a semester when it ends.
    private var archive: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            QBankListGroup(
                footer: model.isArchived
                    ? "Unarchiving brings the semester and its courses back to Home."
                    : "An archived semester moves to Archived, at the bottom of Home, with its courses. Your answers in them stay."
            ) {
                Button {
                    focus = nil
                    Task { await model.toggleArchived() }
                } label: {
                    QBankListRow(
                        "\(model.isArchived ? "Unarchive" : "Archive") \(model.semester?.name ?? "semester")",
                        systemImage: model.isArchived ? "tray.and.arrow.up" : "archivebox"
                    ) {
                        if model.isArchiving {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.qbankRow)
                .disabled(model.isArchiving || model.isSaving)
                .accessibilityIdentifier("semester.archive")
            }
            if let problem = model.archiveProblem {
                ProblemText(text: problem)
            }
            if let note = model.archiveNote {
                SavedText(text: note)
            }
        }
    }

}

/// A list row for an optional calendar date: the date with a way to clear it, or "Add date".
/// Either way the row keeps the list's 44pt height.
struct DayRow: View {
    let title: String
    @Binding var day: Date?
    let identifier: String

    var body: some View {
        if let day {
            QBankListRow(title, accessibilityChildren: .contain) {
                HStack(spacing: 0) {
                    DatePicker(
                        title,
                        selection: Binding(get: { day }, set: { self.day = $0 }),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("\(identifier).date")
                    Button {
                        self.day = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.qbank(.text4))
                            .frame(width: QBankSpacing.rowMin, height: QBankSpacing.rowMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title): clear the date")
                    .accessibilityIdentifier("\(identifier).clear")
                }
                // The picker and the 44pt clear button reach into the row's own padding, so the
                // row is no taller than the others.
                .padding(.vertical, -11)
                .padding(.trailing, -QBankSpacing.space4)
            }
        } else {
            Button {
                day = Calendar.current.startOfDay(for: .now)
            } label: {
                QBankListRow(title) {
                    Text("Add date")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.tint))
                }
            }
            .buttonStyle(.qbankRow)
            .accessibilityLabel("\(title): add a date")
            .accessibilityIdentifier("\(identifier).add")
        }
    }
}
