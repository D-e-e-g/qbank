import QBankDesign
import SwiftUI

/// The fields of a destination that take typing, so the screen that shows them can say which has focus.
enum DestinationField: Hashable {
    case code
    case courseName
    case topicName
    case folderName
}

/// Where a new set goes: the course or topic, a new one's names, and the folder. Import and the
/// set editor both file a set this way (see `SetDestination`). `field` puts a field into the
/// screen's own focus type.
struct DestinationFields<Field: Hashable>: View {
    let destination: SetDestination
    var focus: FocusState<Field?>.Binding
    let field: (DestinationField) -> Field

    var body: some View {
        CourseMenu(destination: destination)
        if destination.courses != nil {
            if destination.makesTopic {
                newTopicField
            } else if destination.makesCourse {
                newCourseFields
            }
        }
        FolderPicker(destination: destination, focus: focus, nameField: field(.folderName))
    }

    /// A new topic needs only its name.
    private var newTopicField: some View {
        @Bindable var destination = destination
        return LabeledField(label: "Topic name") {
            TextField("Spanish verbs", text: $destination.newTopicName)
                .textInputAutocapitalization(.words)
                .focused(focus, equals: field(.topicName))
                .accessibilityLabel("Topic name")
                .accessibilityIdentifier("import.newTopicName")
        }
    }

    private var newCourseFields: some View {
        @Bindable var destination = destination
        return VStack(alignment: .leading, spacing: QBankSpacing.space5) {
            LabeledField(label: "Course code") {
                TextField("BIO 101", text: $destination.newCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused(focus, equals: field(.code))
                    .accessibilityLabel("Course code")
                    .accessibilityIdentifier("import.newCode")
            }
            LabeledField(label: "Course name") {
                TextField("Cell Biology", text: $destination.newTitle)
                    .textInputAutocapitalization(.words)
                    .focused(focus, equals: field(.courseName))
                    .accessibilityLabel("Course name")
                    .accessibilityIdentifier("import.newTitle")
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldTitle("Semester")
                Menu {
                    Picker("Semester", selection: $destination.semesterNumber) {
                        ForEach(1...3, id: \.self) { number in
                            Text("Semester \(number)").tag(number)
                        }
                    }
                } label: {
                    MenuField(text: "Semester \(destination.semesterNumber)")
                }
                .accessibilityLabel("Semester: Semester \(destination.semesterNumber)")
                .accessibilityIdentifier("import.semester")
            }
        }
    }
}
