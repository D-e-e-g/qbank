import QBankDesign
import QBankKit
import SwiftUI
import UniformTypeIdentifiers

/// Import, as the web's Import screen: Choose file or Paste JSON, the course and folder, the set
/// name, then Check file and Import. A set of the same name asks first with the web's replace
/// sheet; once imported, it says where the set went.
struct ImportView: View {
    let app: AppModel
    @State private var model: ImportModel
    /// Opens the folder the set went into.
    let openFolder: (ImportModel.Done) -> Void
    @State private var picksFile = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case paste
        case code
        case courseName
        case topicName
        case folderName
        case title
    }

    /// - Parameters:
    ///   - courseID: The course of the page it was opened from, with its folder or exam page, picked
    ///     when it opens (see `SetDestination`).
    init(app: AppModel, courseID: String? = nil, folderID: String? = nil, examPageID: String? = nil, openFolder: @escaping (ImportModel.Done) -> Void) {
        self.app = app
        self.openFolder = openFolder
        _model = State(initialValue: ImportModel(app: app, courseID: courseID, folderID: folderID, examPageID: examPageID))
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                Group {
                    if let done = model.done {
                        DoneView(done: done) {
                            openFolder(done)
                        } another: {
                            Task { await model.startOver() }
                        }
                    } else {
                        form
                    }
                }
                .screenColumn()
                .padding(.top, QBankSpacing.space2)
                .padding(.bottom, QBankSpacing.space7)
                .id(Self.contentID)
            }
            // The check's answer and the button under it, at the end of the form, come into view
            // together, clear of the tab bar.
            .onChange(of: model.report) { _, report in
                guard report != nil else { return }
                withAnimation { scroller.scrollTo(Self.contentID, anchor: .bottom) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle("Import")
        .screenColumnTitle()
        .task { await model.load() }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.json, .plainText]) { result in
            read(result)
        }
        .sheet(item: $model.conflict) { conflict in
            ReplaceSheet(conflict: conflict) { decision in
                model.conflict = nil
                guard let decision else { return }
                Task { await model.commit(decision) }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space5) {
            if !model.isOnline {
                OfflineBanner(title: "Importing needs a connection", message: "QBank checks the file and files the set on the server. Practice works offline.")
                    .accessibilityIdentifier("import.offline")
            }
            QBankSegmentedControl(
                "How to add the file",
                selection: $model.mode,
                options: [.init(.file, "Choose file"), .init(.paste, "Paste JSON")]
            )
            .accessibilityIdentifier("import.mode")
            switch model.mode {
            case .file: filePick
            case .paste: pasteField
            }
            CourseMenu(destination: model.destination)
            if model.destination.courses != nil {
                if model.destination.makesTopic {
                    newTopicField
                } else if model.destination.makesCourse {
                    newCourseFields
                }
            }
            FolderPicker(destination: model.destination, focus: $focus, nameField: .folderName)
            LabeledField(label: "Set name", hint: "Filled from the file’s title. You can change it.") {
                TextField("Set name", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .accessibilityIdentifier("import.title")
            }
            if let report = model.report {
                ReportView(report: report, copied: model.copied) {
                    UIPasteboard.general.string = model.copyErrors()
                }
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            action
        }
    }

    private static let contentID = "import.content"

    private var filePick: some View {
        Button {
            app.frozen.perform { picksFile = true }
        } label: {
            HStack(spacing: QBankSpacing.space3) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.qbank(.tint))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.fileName ?? "Choose a JSON file")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("From Files or iCloud Drive.")
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.qbank(.text4))
                    .accessibilityHidden(true)
            }
            .padding(QBankSpacing.space4)
            .frame(minHeight: 72)
            .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                    .strokeBorder(.qbank(.separatorStrong), style: StrokeStyle(lineWidth: QBankBorder.regular, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Files")
        .accessibilityIdentifier("import.file")
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("Paste JSON")
            TextEditor(text: Binding(get: { model.source }, set: { model.setSource($0) }))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.qbank(.text1))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .paste)
                .padding(.horizontal, QBankSpacing.space3)
                .padding(.vertical, QBankSpacing.space2)
                .frame(height: 168)
                .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                        .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
                }
                .accessibilityLabel("Paste JSON")
                .accessibilityIdentifier("import.paste")
            FieldHint("Paste the JSON from your agent.")
        }
    }

    /// A new topic needs only its name.
    private var newTopicField: some View {
        @Bindable var destination = model.destination
        return LabeledField(label: "Topic name") {
            TextField("Spanish verbs", text: $destination.newTopicName)
                .textInputAutocapitalization(.words)
                .focused($focus, equals: .topicName)
                .accessibilityLabel("Topic name")
                .accessibilityIdentifier("import.newTopicName")
        }
    }

    private var newCourseFields: some View {
        @Bindable var destination = model.destination
        return VStack(alignment: .leading, spacing: QBankSpacing.space5) {
            LabeledField(label: "Course code") {
                TextField("NURS 406", text: $destination.newCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .code)
                    .accessibilityLabel("Course code")
                    .accessibilityIdentifier("import.newCode")
            }
            LabeledField(label: "Course name") {
                TextField("Mental Health", text: $destination.newTitle)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .courseName)
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

    @ViewBuilder
    private var action: some View {
        if model.canImport {
            Button {
                focus = nil
                Task { await model.commit() }
            } label: {
                ButtonLabel(text: "Import", isBusy: model.isBusy)
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(model.isBusy || !model.isOnline)
            .accessibilityIdentifier("import.commit")
        } else {
            Button {
                focus = nil
                Task { await model.check() }
            } label: {
                ButtonLabel(text: "Check file", isBusy: model.isBusy)
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(!model.canCheck)
            .answersWhenFrozen(app.frozen)
            .accessibilityIdentifier("import.check")
        }
    }

    /// Reads the file she picked in Files. It lives outside the app, so it is opened for the read.
    private func read(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.fileFailed("That file could not be opened. Try choosing it again.")
                return
            }
            model.chooseFile(named: url.lastPathComponent, text: String(decoding: data, as: UTF8.self))
        case .failure:
            model.fileFailed("That file could not be opened. Try choosing it again.")
        }
    }
}

/// Import as a sheet over the page it was opened from, with that page's course picked: "Import here"
/// on a folder, with the folder picked, or a course's or an exam page's +. Its done screen's Open
/// goes to the folder the set went into.
struct ImportHereSheet: View {
    let app: AppModel
    let courseID: String
    var folderID: String?
    var examPageID: String?
    let finished: (ImportedSet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ImportView(app: app, courseID: courseID, folderID: folderID, examPageID: examPageID) { finished($0.set) }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("import.cancel")
                    }
                }
        }
    }
}

/// The course a new set goes into, as a menu of her courses, then New course and New topic when
/// the import can make one. Once she has a study topic, her courses and her topics are two groups.
struct CourseMenu: View {
    let destination: SetDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("Course")
            Menu {
                Picker("Course", selection: Binding(get: { destination.menuChoice }, set: { next in
                    Task { await destination.chooseCourse(next) }
                })) {
                    let courses = destination.courses ?? []
                    if destination.topics.isEmpty {
                        options(courses)
                    } else {
                        if !courses.isEmpty {
                            Section("Courses") { options(courses) }
                        }
                        Section("Study topics") { options(destination.topics) }
                    }
                    if destination.allowsNewCourse {
                        Text("New course").tag(SetDestination.CourseChoice.new)
                        Text("New topic").tag(SetDestination.CourseChoice.newTopic)
                    }
                }
            } label: {
                MenuField(text: destination.courseLabel)
            }
            .disabled(destination.courses == nil)
            .accessibilityLabel("Course: \(destination.courseLabel)")
            .accessibilityIdentifier("import.course")
        }
    }

    private func options(_ courses: [CourseSummary]) -> some View {
        ForEach(courses) { course in
            Text(SetDestination.label(course)).tag(SetDestination.CourseChoice.existing(course.id))
        }
    }
}

/// The folder a new set goes into: Unsorted unless she picks one of her folders, grouped by exam
/// page, or names a new one.
struct FolderPicker<Field: Hashable>: View {
    @Bindable var destination: SetDestination
    var focus: FocusState<Field?>.Binding
    let nameField: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("Folder")
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                FlowLayout(spacing: QBankSpacing.space2, lineSpacing: QBankSpacing.space2) {
                    PickChip(title: SetDestination.unsorted, note: destination.unsortedExists ? nil : "new", isOn: destination.folder == .unsorted) {
                        destination.folder = .unsorted
                    }
                    .accessibilityIdentifier("import.folder.Unsorted")
                }
                ForEach(destination.folderGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title.uppercased())
                            .qbankFont(.caption1, weight: .semibold, trackingEm: QBankTextStyle.capsTrackingEm)
                            .foregroundStyle(.qbank(.text3))
                            .accessibilityLabel(group.title)
                            .accessibilityAddTraits(.isHeader)
                        FlowLayout(spacing: QBankSpacing.space2, lineSpacing: QBankSpacing.space2) {
                            ForEach(group.folders) { folder in
                                PickChip(title: folder.name, isOn: destination.folder == .folder(folder.id)) {
                                    destination.folder = .folder(folder.id)
                                }
                                .accessibilityIdentifier("import.folder.\(group.title).\(folder.name)")
                            }
                        }
                    }
                }
                FlowLayout(spacing: QBankSpacing.space2, lineSpacing: QBankSpacing.space2) {
                    PickChip(title: "New folder", systemImage: "plus", isOn: destination.folder == .new) {
                        destination.folder = .new
                        focus.wrappedValue = nameField
                    }
                    .accessibilityIdentifier("import.folder.new")
                }
                if destination.folder == .new {
                    TextField("Folder name", text: $destination.newFolderName)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .textInputAutocapitalization(.words)
                        .focused(focus, equals: nameField)
                        .padding(.horizontal, QBankSpacing.space4)
                        .frame(minHeight: QBankButtonStyle.Size.medium.minHeight)
                        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
                        }
                        .accessibilityLabel("New folder name")
                        .accessibilityIdentifier("import.folder.newName")
                }
            }
            FieldHint("Pick a folder now, or leave it in Unsorted and move it later.")
        }
    }
}

/// The check's answer: Ready with the format counts, the errors that block the file with a way to
/// copy them for your agent, and warnings.
private struct ReportView: View {
    let report: ImportReport
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            if report.ok {
                VStack(alignment: .leading, spacing: 10) {
                    Label(ImportWording.ready(report), systemImage: "checkmark.circle")
                        .qbankFont(.headline)
                        .foregroundStyle(.qbank(.correct))
                        .accessibilityIdentifier("import.ready")
                    if report.kind == .exam {
                        Text(ImportWording.examNote)
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text1))
                    }
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(report.formats, id: \.type) { format in
                            Text("\(format.count) \(format.label)")
                                .qbankFont(.caption1, weight: .medium)
                                .foregroundStyle(.qbank(.text2))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.qbank(.surfaceRaised), in: .capsule)
                                .overlay(Capsule().strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline))
                        }
                    }
                }
                .padding(QBankSpacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.qbank(.correctSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous).strokeBorder(.qbank(.correctBorder), lineWidth: QBankBorder.regular))
            }
            if !report.errors.isEmpty {
                VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                    Issues(items: report.errors)
                    Button(copied ? "Copied" : "Copy these for your agent", action: copy)
                        .buttonStyle(.qbank(.secondary, size: .small))
                        .accessibilityIdentifier("import.copyErrors")
                }
                .padding(QBankSpacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.qbank(.wrongSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous).strokeBorder(.qbank(.wrongBorder), lineWidth: QBankBorder.regular))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("import.errors")
            }
            if !report.warnings.isEmpty {
                Issues(items: report.warnings)
                    .padding(QBankSpacing.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.qbank(.partialSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous).strokeBorder(.qbank(.partialBorder), lineWidth: QBankBorder.regular))
                    .accessibilityIdentifier("import.warnings")
            }
        }
    }
}

/// A bulleted list of the importer's lines.
private struct Issues: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: QBankSpacing.space2) {
                    Text("•")
                        .accessibilityHidden(true)
                    Text(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .qbankFont(.footnote)
                .foregroundStyle(.qbank(.text1))
            }
        }
    }
}

/// The web's replace question: Replace, Import as a separate set, or Cancel, all always visible.
private struct ReplaceSheet: View {
    let conflict: ImportConflict
    let answer: (ImportRequest.Decision?) -> Void
    @State private var height: CGFloat = 340

    var body: some View {
        VStack(spacing: QBankSpacing.space3) {
            Text(ImportWording.replaceTitle(conflict))
                .qbankFont(.headline)
                .foregroundStyle(.qbank(.text1))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("import.replace.title")
            Text(ImportWording.replaceMessage(conflict))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .multilineTextAlignment(.center)
                .padding(.bottom, QBankSpacing.space3)
                .accessibilityIdentifier("import.replace.message")
            Button("Replace") { answer(.replace) }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("import.replace.confirm")
            Button("Import as a separate set") { answer(.separate) }
                .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                .accessibilityIdentifier("import.replace.separate")
            Button("Cancel") { answer(nil) }
                .buttonStyle(.qbank(.quiet, size: .large, fullWidth: true))
                .accessibilityIdentifier("import.replace.cancel")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, QBankSpacing.gutterPhone)
        .padding(.top, 28)
        .padding(.bottom, QBankSpacing.space4)
        .frame(maxWidth: QBankLayout.contentMax)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationBackground(.qbank(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.replace")
    }
}

/// Imported or Replaced: where the set went, Open its folder, and Import another file.
private struct DoneView: View {
    let done: ImportModel.Done
    let open: () -> Void
    let another: () -> Void

    var body: some View {
        VStack(spacing: QBankSpacing.space3) {
            DoneMark(systemImage: done.set.kind == .replaced ? "arrow.counterclockwise" : "checkmark")
            Text(done.set.kind == .replaced ? "Replaced" : "Imported")
                .qbankFont(.title1)
                .foregroundStyle(.qbank(.text1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("import.done.title")
            Text(ImportWording.doneCopy(done))
                .qbankFont(.callout)
                .foregroundStyle(.qbank(.text2))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .accessibilityIdentifier("import.done.copy")
            VStack(spacing: QBankSpacing.space2) {
                Button("Open \(done.set.folderName)", action: open)
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("import.done.open")
                Button("Import another file", action: another)
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .accessibilityIdentifier("import.done.another")
            }
            .padding(.top, QBankSpacing.space4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, QBankSpacing.space7)
    }
}
