import PhotosUI
import QBankDesign
import QBankKit
import SwiftUI
import UniformTypeIdentifiers

/// Your material (Q-2): pasted notes, photos, or a PDF, what the photos hold, and the course and
/// folder the set goes into. Notes go on to the level; photos of practice questions are copied.
struct MaterialView: View {
    let app: AppModel
    @Bindable var model: MakeModel
    /// Writing: on to Level and count.
    let next: () -> Void
    /// Copying: the server is finding the questions in the photos.
    let started: (QuestionJob) -> Void
    @State private var picksPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takesPhoto = false
    @State private var picksFile = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case notes
        case folderName
    }

    /// The files the server reads: a PDF, or plain or Markdown text.
    static let markdown = UTType(filenameExtension: "md")
    static let fileTypes: [UTType] = [.pdf, .plainText] + [markdown].compactMap(\.self)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space5) {
                if !app.connection.isOnline {
                    OfflineBanner(title: "Making questions needs a connection", message: "QBank reads your material and writes the questions on the server. Practice works offline.")
                }
                QBankSegmentedControl("Material", selection: $model.source, options: [.init(.paste, "Paste"), .init(.photos, "Photos"), .init(.file, "File")])
                    .accessibilityIdentifier("make.source")
                switch model.source {
                case .paste: notes
                case .photos: photos
                case .file: filePick
                }
                CourseMenu(destination: model.destination)
                FolderPicker(destination: model.destination, focus: $focus, nameField: .folderName)
                if model.copies {
                    QBankListGroup {
                        TwinToggle(isOn: $model.examTwins, detail: "So the exam asks it in new words")
                    }
                }
                if let problem = model.problem {
                    ProblemText(text: problem)
                }
                Button {
                    focus = nil
                    if model.copies {
                        Task {
                            if let job = await model.start() { started(job) }
                        }
                    } else {
                        next()
                    }
                } label: {
                    ButtonLabel(text: model.copies ? "Find the questions" : "Next", isBusy: model.isStarting)
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(!model.canGoOn || !app.connection.isOnline)
                .accessibilityIdentifier("make.next")
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space2)
            .padding(.bottom, QBankSpacing.space7)
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle("Your material")
        .screenColumnTitle()
        // As in the wireframes, the steps of a new set take the whole screen.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                StepTitle(step: 1, of: model.copies ? 2 : 4)
            }
        }
        .task { await model.load() }
        .photosPicker(isPresented: $picksPhotos, selection: $photoItems, maxSelectionCount: max(1, model.maxPhotos - model.photos.count), matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = await PhotoShrinker.jpeg(from: data) {
                        model.add(photo: jpeg)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $takesPhoto) {
            CameraPicker { image in
                takesPhoto = false
                guard let image else { return }
                Task {
                    if let jpeg = await PhotoShrinker.jpeg(from: image) { model.add(photo: jpeg) }
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: MaterialView.fileTypes) { result in
            read(result)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("Your notes")
            TextEditor(text: $model.text)
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .notes)
                .padding(.horizontal, QBankSpacing.space3)
                .padding(.vertical, QBankSpacing.space2)
                .frame(height: 200)
                .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                        .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
                }
                .accessibilityLabel("Your notes")
                .accessibilityIdentifier("make.notes")
            FieldHint("Paste or type your lecture notes. QBank writes new questions from them.")
        }
    }

    private var photos: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            QBankListGroup(header: "What is in the photos") {
                HoldingRow(
                    title: "Notes or slides",
                    detail: "QBank writes new questions from them",
                    isPicked: model.holding == .notes
                ) { model.holding = .notes }
                .accessibilityIdentifier("make.holding.notes")
                HoldingRow(
                    title: "Practice questions",
                    detail: "A quiz, a worksheet, a review book page: QBank copies them in as they are",
                    isPicked: model.holding == .questions
                ) { model.holding = .questions }
                .accessibilityIdentifier("make.holding.questions")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: QBankSpacing.space2), count: 3), spacing: QBankSpacing.space2) {
                ForEach(model.photos) { photo in
                    PhotoTile(photo: photo) { model.remove(photo) }
                }
                if model.photos.count < model.maxPhotos {
                    Menu {
                        if CameraPicker.isAvailable {
                            Button("Take photo", systemImage: "camera") { takesPhoto = true }
                        }
                        Button("Choose from library", systemImage: "photo.on.rectangle") { picksPhotos = true }
                    } label: {
                        AddPhotoTile()
                    }
                    .accessibilityLabel("Take or choose photo")
                    .accessibilityIdentifier("make.addPhoto")
                }
            }
            FieldHint("\(model.photoLine) Paste takes typed notes; File takes a PDF of slides.")
        }
    }

    private var filePick: some View {
        Button {
            picksFile = true
        } label: {
            HStack(spacing: QBankSpacing.space3) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.qbank(.tint))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.file?.name ?? "Choose a PDF or text file")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Slides saved as a PDF, or typed notes, from Files or iCloud Drive.")
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
        .accessibilityIdentifier("make.file")
    }

    /// Reads the PDF she picked in Files. It lives outside the app, so it is opened for the read.
    private func read(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else {
            model.fileFailed("That file could not be opened. Try choosing it again.")
            return
        }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.fileFailed("That file could not be opened. Try choosing it again.")
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let mediaType = type?.conforms(to: .pdf) == true ? "application/pdf" : type == Self.markdown ? "text/markdown" : "text/plain"
        model.choose(file: MakeModel.File(name: url.lastPathComponent, mediaType: mediaType, data: data))
    }
}

/// Level and count (Q-3): her recipe's level, how many, the formats it writes, and exam twins.
struct LevelView: View {
    let app: AppModel
    @Bindable var model: MakeModel
    let started: (QuestionJob) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space5) {
                QBankListGroup(header: "Level", footer: MakeWording.levels) {
                    QBankSegmentedControl("Level", selection: $model.level, options: QuestionLevel.allCases.map { .init($0, MakeWording.level($0)) })
                        .padding(QBankSpacing.space3)
                        .accessibilityIdentifier("make.level")
                }
                QBankListGroup {
                    ReferenceRow(model: model)
                        .disabled(model.level != .exam)
                }
                QBankListGroup(header: "How many questions") {
                    QBankListRow(Wording.count(model.count, "question"), detail: MakeWording.writingTime(count: model.count), accessibilityChildren: .contain) {
                        Stepper("How many questions", value: $model.count, in: model.countRange)
                            .labelsHidden()
                            .accessibilityIdentifier("make.count")
                    }
                    .accessibilityIdentifier("make.countRow")
                }
                QBankListGroup(header: "Question kinds") {
                    let kinds = MakeWording.kinds(model.level)
                    QBankListRow(kinds.title, detail: kinds.detail)
                        .accessibilityIdentifier("make.kinds")
                    TwinToggle(isOn: $model.examTwins, detail: "Same topic, different format and wording, for exams only")
                }
                if let problem = model.problem {
                    ProblemText(text: problem)
                }
                Button {
                    Task {
                        if let job = await model.start() { started(job) }
                    }
                } label: {
                    ButtonLabel(text: "Write 5 samples first", isBusy: model.isStarting)
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(model.isStarting || !app.connection.isOnline)
                .accessibilityIdentifier("make.start")
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space2)
            .padding(.bottom, QBankSpacing.space7)
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle("Level and count")
        .screenColumnTitle()
        .toolbar(.hidden, for: .tabBar)
        .task { await model.loadReferences() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                StepTitle(step: 2, of: 4)
            }
        }
    }
}

/// Measured against: the practice set she treats as the bar at exam level, from any of her courses.
private struct ReferenceRow: View {
    let model: MakeModel
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            Picker("Measured against", selection: Binding(get: { model.referenceSetID }, set: { model.referenceSetID = $0 })) {
                Text("None").tag(String?.none)
                ForEach(model.references ?? []) { group in
                    Section(group.title) {
                        ForEach(group.sets) { set in
                            Text(set.title).tag(Optional(set.id))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: QBankSpacing.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured against")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                    Text("Exam level only: the questions you treat as the bar, like Success Coach, NURS 420")
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(model.referenceTitle)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text3))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.qbank(.text4))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .frame(minHeight: QBankSpacing.rowMin)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Measured against: \(model.referenceTitle)")
        .accessibilityIdentifier("make.reference")
    }
}

/// "Step 2 of 4", in the middle of the navigation bar above the large title.
struct StepTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    init(step: Int, of: Int) {
        text = Self.text(step: step, of: of)
    }

    /// "Step 1 of 4".
    static func text(step: Int, of: Int) -> String {
        "Step \(step) of \(of)"
    }

    var body: some View {
        Text(text)
            .qbankFont(.subheadline, weight: .semibold)
            .foregroundStyle(.qbank(.text2))
    }
}

/// The exam twin switch: one twin for each question, asked only on exams.
struct TwinToggle: View {
    @Binding var isOn: Bool
    let detail: String

    var body: some View {
        QBankListRow("Also write an exam twin for each", detail: detail, accessibilityChildren: .contain) {
            Toggle("Also write an exam twin for each", isOn: $isOn)
                .labelsHidden()
                .tint(QBankColor(.tint))
        }
        .accessibilityIdentifier("make.twins")
    }
}

/// One answer to "What is in the photos", picked with a check circle.
private struct HoldingRow: View {
    let title: String
    let detail: String
    let isPicked: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: QBankSpacing.space4) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(.qbank(isPicked ? .tint : .separatorStrong))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                    Text(detail)
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .frame(minHeight: QBankSpacing.rowMin)
            .contentShape(.rect)
        }
        .buttonStyle(.qbankRow)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? [.isSelected, .isButton] : .isButton)
    }
}

/// A photo she added, with a way to take it out.
private struct PhotoTile: View {
    let photo: MakeModel.Photo
    let remove: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let image = UIImage(data: photo.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .padding(6)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Remove photo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Photo")
    }
}

/// The dashed tile that adds a photo.
private struct AddPhotoTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.qbank(.separatorStrong), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "camera")
                        .font(.title3)
                    Text("Take or\nchoose photo")
                        .qbankFont(.caption1, weight: .semibold)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.qbank(.text2))
            }
            .contentShape(.rect)
    }
}

/// Photos go to the server as JPEGs no longer than 1,568 pixels on a side: Claude reads no more,
/// and it keeps a set of 20 photos small enough to send.
nonisolated enum PhotoShrinker {
    static let maxSide: CGFloat = 1568

    static func jpeg(from data: Data) async -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return await jpeg(from: image)
    }

    @concurrent
    static func jpeg(from image: UIImage) async -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}

/// The camera, for photographing slides, notes, or a quiz page.
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (UIImage?) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(taken: taken)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let taken: (UIImage?) -> Void

        init(taken: @escaping (UIImage?) -> Void) {
            self.taken = taken
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            taken(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            taken(nil)
        }
    }
}
