import QBankDesign
import QBankKit
import SwiftUI

/// Where a row of the Add tab leads.
enum AddRoute: Hashable {
    case importFile
    /// Your material (Q-2).
    case material
    /// Level and count (Q-3).
    case level
    /// A set being made, on whichever step it is.
    case job(String)
}

/// The Add tab: the ways to add questions, and her sets still being made. Import is for everyone;
/// Make questions shows only when the server says this account may use it. A course's + opens
/// Make questions here, with that course picked.
struct AddView: View {
    let app: AppModel
    @State private var path = NavigationPath()
    @State private var model: AddModel
    /// Her material and picks while she makes a set, kept so starting over keeps her photos.
    @State private var making: MakeModel?
    /// The set she just started, as the server answered, until the hub lists it.
    @State private var started: QuestionJob?
    @Environment(TabNavigator.self) private var tabs

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: AddModel(app: app))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: QBankSpacing.space7) {
                    ways
                    if !model.inProgress.isEmpty {
                        inProgress
                    }
                }
                .screenColumn()
                .padding(.top, QBankSpacing.space3)
                .padding(.bottom, QBankSpacing.space7)
            }
            .qbankScreenBackground()
            .navigationTitle("Add questions")
            .screenColumnTitle()
            .refreshable { await model.load() }
            .task(id: path.isEmpty) {
                if path.isEmpty { await model.load() }
            }
            .navigationDestination(for: AddRoute.self) { route in
                destination(route)
            }
        }
        .frozenNote(app.frozen)
        .onChange(of: tabs.makeRequest, initial: true) { _, request in
            guard let request else { return }
            tabs.makeRequest = nil
            making = MakeModel(app: app, status: request.status ?? model.status, courseID: request.courseID)
            var next = NavigationPath()
            next.append(AddRoute.material)
            path = next
        }
    }

    @ViewBuilder
    private func destination(_ route: AddRoute) -> some View {
        switch route {
        case .importFile:
            ImportView(app: app) { done in
                tabs.openFolder(courseID: done.set.courseID, name: done.courseName, folderID: done.set.folderID)
            }
        case .material:
            if let making {
                MaterialView(app: app, model: making) {
                    path.append(AddRoute.level)
                } started: { job in
                    follow(job)
                }
            }
        case .level:
            if let making {
                LevelView(app: app, model: making) { job in
                    follow(job)
                }
            }
        case .job(let id):
            JobView(app: app, id: id, seed: started?.id == id ? started : model.jobs.first { $0.id == id }) {
                path = NavigationPath()
            } startOver: {
                // Her material stays when she made the set in this session, so she can retake
                // one photo and keep the rest.
                if making == nil { making = MakeModel(app: app, status: model.status) }
                var next = NavigationPath()
                next.append(AddRoute.material)
                path = next
            }
            .id(id)
        }
    }

    /// Once the server has the set, its steps replace Your material and Level, so going back
    /// leads to Add and never starts it twice.
    private func follow(_ job: QuestionJob) {
        started = job
        var next = NavigationPath()
        next.append(AddRoute.job(job.id))
        path = next
    }

    private var ways: some View {
        QBankListGroup(footer: model.makeNote) {
            if model.canMake {
                Button {
                    making = MakeModel(app: app, status: model.status)
                    path.append(AddRoute.material)
                } label: {
                    WayRow(
                        title: "Make questions from your material",
                        detail: "Paste notes or photograph slides. QBank writes NCLEX-style questions and checks them.",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.qbankRow)
                .disabled(!app.connection.isOnline)
                .accessibilityIdentifier("add.make")
            }
            NavigationLink(value: AddRoute.importFile) {
                WayRow(
                    title: "Import a question file",
                    detail: "A JSON file from your agent.",
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("add.import")
        }
    }

    private var inProgress: some View {
        QBankListGroup(header: "In progress") {
            ForEach(model.inProgress) { job in
                NavigationLink(value: AddRoute.job(job.id)) {
                    QBankListRow(MakeWording.title(job), detail: MakeWording.progress(job), showsChevron: true)
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("add.job.\(job.id)")
            }
        }
    }
}

/// A way to add questions: a tall row with what it does under its name.
struct WayRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        QBankListRow(title, detail: detail, systemImage: systemImage, showsChevron: true)
            .frame(minHeight: 72)
    }
}
