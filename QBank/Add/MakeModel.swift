import Foundation
import Observation
import QBankKit

/// Making a set from her material (Q-2 and Q-3): what she gives (pasted notes, photos, or a file),
/// where the set goes, exam twins, and for notes, the level, how many, and the set to measure the
/// level against. Photos of practice questions are copied instead, so they skip the level. The
/// server does the reading and writing.
@Observable
final class MakeModel {
    enum Source: Hashable {
        case paste
        case photos
        case file
    }

    /// A photo she took or chose, as the JPEG the server reads.
    struct Photo: Identifiable, Equatable {
        let id = UUID()
        let data: Data
    }

    /// A PDF or text file she chose in Files.
    struct File: Equatable {
        let name: String
        let mediaType: String
        let data: Data
    }

    /// Her practice sets in one course, which she can measure exam level against.
    struct ReferenceGroup: Identifiable, Equatable {
        struct Choice: Identifiable, Equatable {
            let id: String
            let title: String
        }

        let id: String
        let title: String
        let sets: [Choice]
    }

    var source: Source = .photos
    var text = ""
    private(set) var photos: [Photo] = []
    /// What her photos hold: notes to write from, or practice questions to copy.
    var holding: MaterialKind = .notes
    private(set) var file: File?
    /// The course and folder the set is filed under.
    let destination: SetDestination
    var level: QuestionLevel {
        didSet {
            count = min(max(count, countRange.lowerBound), countRange.upperBound)
            if level != .exam { referenceSetID = nil }
        }
    }
    var count: Int
    /// Exam level only: the practice set she treats as the bar.
    var referenceSetID: String?
    /// Her practice sets by course, for the reference picker, once read.
    private(set) var references: [ReferenceGroup]?
    var examTwins = true
    private(set) var isStarting = false
    /// Why the server did not start it, in its words.
    private(set) var problem: String?

    private let app: AppModel
    /// The server's choices and limits, or nil when they could not be read; its own rules then
    /// still refuse anything out of range, in its words.
    let status: QuestionMakerStatus?

    /// `courseID` is the course whose + opened it, picked when it opens.
    init(app: AppModel, status: QuestionMakerStatus?, courseID: String? = nil) {
        self.app = app
        self.status = status
        destination = SetDestination(app: app, courseID: courseID, allowsNewCourse: false)
        let level = status?.defaultLevel ?? .exam
        self.level = level
        count = status?.range(of: level).defaultCount ?? 15
    }

    func load() async {
        do {
            try await destination.load()
        } catch {
            if app.handle(error) { return }
            // Without a connection the banner already says why nothing is here.
            problem = app.connection.isOnline ? Wording.problem(error) : nil
        }
    }

    var maxPhotos: Int {
        status?.limits.photos ?? 20
    }

    /// How many questions a set at her level may have.
    var countRange: ClosedRange<Int> {
        guard let range = status?.range(of: level), range.minCount <= range.maxCount else { return 10...15 }
        return range.minCount...range.maxCount
    }

    /// Photos of practice questions are copied in as they are; anything else is written from.
    var copies: Bool {
        source == .photos && holding == .questions
    }

    var hasMaterial: Bool {
        switch source {
        case .paste: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .photos: !photos.isEmpty
        case .file: file != nil
        }
    }

    /// Next on Your material: material, one of her courses, and a folder.
    var canGoOn: Bool {
        hasMaterial && destination.courseID != nil && destination.importFolder != nil && !isStarting
    }

    /// "4 photos · slides or handwritten notes, up to 20."
    var photoLine: String {
        let kind = holding == .notes ? "slides or handwritten notes" : "quiz, worksheet, or review book pages"
        return photos.isEmpty ? "Up to \(maxPhotos) photos of \(kind)." : "\(Wording.count(photos.count, "photo")) · \(kind), up to \(maxPhotos)."
    }

    func add(photo data: Data) {
        guard photos.count < maxPhotos else { return }
        photos.append(Photo(data: data))
    }

    func remove(_ photo: Photo) {
        photos.removeAll { $0.id == photo.id }
    }

    func choose(file: File) {
        self.file = file
        problem = nil
    }

    func fileFailed(_ message: String) {
        problem = message
    }

    /// The reference set's name, or "None".
    var referenceTitle: String {
        guard let referenceSetID else { return "None" }
        return references?.lazy.flatMap(\.sets).first { $0.id == referenceSetID }?.title ?? "None"
    }

    /// Her practice sets in every course and topic she studies, for the reference picker.
    func loadReferences() async {
        guard references == nil else { return }
        let catalog = try? await app.load(.catalog) { () async throws(QBankError) in try await app.client.catalog() }.value
        var groups: [ReferenceGroup] = []
        for course in catalog?.everyCourse ?? [] where course.archivedAt == nil {
            let id = course.id
            guard let detail = try? await app.load(.course(id), from: { () async throws(QBankError) in try await app.client.course(id: id) }).value else { continue }
            let sets = detail.folders.flatMap(\.sets).map { ReferenceGroup.Choice(id: $0.id, title: $0.title) }
            if !sets.isEmpty { groups.append(ReferenceGroup(id: course.id, title: Wording.name(course), sets: sets)) }
        }
        references = groups
    }

    /// What she starts, as the server takes it.
    var job: NewQuestionJob? {
        guard let courseID = destination.courseID, let folder = destination.importFolder else { return nil }
        var folderID: String?
        var folderName: String?
        switch folder {
        case .unsorted: break
        case .id(let id): folderID = id
        case .named(let name): folderName = name
        }
        var text: String?
        var images: [NewQuestionJob.Image] = []
        var file: NewQuestionJob.File?
        switch source {
        case .paste:
            let notes = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { return nil }
            text = notes
        case .photos:
            guard !photos.isEmpty else { return nil }
            images = photos.map { NewQuestionJob.Image(mediaType: "image/jpeg", data: $0.data) }
        case .file:
            guard let chosen = self.file else { return nil }
            file = NewQuestionJob.File(name: chosen.name, mediaType: chosen.mediaType, data: chosen.data)
        }
        return NewQuestionJob(
            courseID: courseID,
            folderID: folderID,
            folderName: folderName,
            materialKind: copies ? .questions : .notes,
            text: text,
            images: images,
            file: file,
            level: copies ? nil : level,
            count: copies ? nil : count,
            referenceSetID: !copies && level == .exam ? referenceSetID : nil,
            examTwins: examTwins
        )
    }

    /// Starts the set on the server: copying the questions in her photos, or writing five samples
    /// at her level. A refusal is said in the server's words.
    func start() async -> QuestionJob? {
        guard let job else { return nil }
        // Nothing of hers goes to Anthropic before she allows it, whatever screen got here.
        guard app.aiConsent.isAllowed else {
            problem = AIConsentWording.needed
            return nil
        }
        problem = nil
        isStarting = true
        defer { isStarting = false }
        do {
            return try await app.client.startQuestionJob(job)
        } catch {
            if app.handle(error) { return nil }
            problem = Wording.problem(error)
            return nil
        }
    }
}
