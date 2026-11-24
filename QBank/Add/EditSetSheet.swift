import QBankDesign
import QBankKit
import SwiftUI

/// A saved set opened in the set editor, from its row in a folder. Her unsaved changes to this set
/// come back if she left them, and the editor says when the set has a newer version than they were
/// made on; otherwise the set is read as it is now. A set the editor cannot keep whole is not
/// opened, and the sheet says why.
struct EditSetSheet: View {
    let app: AppModel
    let set: PracticeSetSummary
    let courseID: String
    let folderID: String
    let finished: (ImportedSet) -> Void
    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case open(SetDraft)
        case refused(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("edit.loading")
                case .open(let draft):
                    WriteView(app: app, draft: draft) { done in
                        finished(done.set)
                        dismiss()
                    }
                case .refused(let message):
                    EmptyCard(message: message, systemImage: "square.and.pencil")
                        .screenColumn()
                        .padding(.top, QBankSpacing.space4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .qbankScreenBackground()
                        .navigationTitle("Edit questions")
                        .accessibilityIdentifier("edit.refused")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("edit.close")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let kept = app.drafts.drafts.first(where: { $0.editing?.setID == set.id }) {
            phase = .open(kept)
            return
        }
        do {
            switch try await WriteEdit.open(setID: set.id, courseID: courseID, folderID: folderID, client: app.client) {
            case .success(let draft): phase = .open(draft)
            case .failure(let refusal): phase = .refused(refusal.message)
            }
        } catch {
            if app.handle(error) { return }
            phase = .refused(Wording.problem(error) ?? "Could not open that set.")
        }
    }
}
