import QBankDesign
import QBankKit
import SwiftUI

extension View {
    /// Asks before a delete, from the server's warning: what goes with it, in the server's words,
    /// Delete and Cancel. `deleted` runs once it is deleted, before the sheet closes.
    func deleteSheet(app: AppModel, request: Binding<DeleteRequest?>, deleted: @escaping (DeleteTarget) -> Void = { _ in }) -> some View {
        sheet(item: request) { request in
            DeleteSheet(app: app, target: request.target) {
                deleted(request.target)
            }
        }
    }

    /// The Undo bar over the bottom of a screen, for her last delete.
    func undoBar(_ app: AppModel) -> some View {
        overlay(alignment: .bottom) {
            UndoBar(deletions: app.deletions, app: app)
        }
    }
}

/// The confirmation before a delete. It opens at once and reads what goes; a delete refused for
/// now says why and waits, and one whose warning changed reads it again before anything goes.
private struct DeleteSheet: View {
    @State private var model: DeleteModel
    let deleted: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, target: DeleteTarget, deleted: @escaping () -> Void) {
        _model = State(initialValue: DeleteModel(app: app, target: target))
        self.deleted = deleted
    }

    var body: some View {
        ConfirmSheet(
            title: model.title,
            message: model.warning?.message ?? "",
            confirm: "Delete",
            identifier: "deleteSheet",
            isBusy: model.isDeleting,
            isLoading: model.warning == nil && model.problem == nil,
            canConfirm: model.canDelete,
            problem: model.problem ?? model.warning?.refusal
        ) { confirmed in
            guard confirmed else {
                dismiss()
                return
            }
            Task {
                if await model.delete() {
                    deleted()
                    dismiss()
                }
            }
        }
        .task { await model.load() }
    }
}

/// The confirmation before deleting the sets she ticked. It reads every set's warning, and a refusal
/// says why and waits. Closed after a refusal stopped it partway, Undo covers what went.
struct DeleteSetsSheet: View {
    @State private var model: DeleteSetsModel
    let deleted: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, sets: [PracticeSetSummary], deleted: @escaping () -> Void) {
        _model = State(initialValue: DeleteSetsModel(app: app, sets: sets))
        self.deleted = deleted
    }

    var body: some View {
        ConfirmSheet(
            title: model.title,
            message: model.message,
            messageMaxHeight: 320,
            confirm: "Delete",
            identifier: "deleteSheet",
            isBusy: model.isDeleting,
            isLoading: model.isLoading,
            canConfirm: model.canDelete,
            problem: model.problem
        ) { confirmed in
            guard confirmed else {
                dismiss()
                return
            }
            Task {
                if await model.delete() {
                    deleted()
                    dismiss()
                }
            }
        }
        .task { await model.load() }
        .onDisappear { model.offerUndo() }
    }
}

/// Her last delete at the bottom of the screen, with Undo, for a few seconds. Recently deleted
/// keeps it for 30 days.
private struct UndoBar: View {
    let deletions: Deletions
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let offer = deletions.offer {
                bar(offer)
                    .task(id: offer.state) {
                        guard let seconds = Self.shownFor(offer.state) else { return }
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled else { return }
                        deletions.dismiss(offer.id)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : QBankMotion.reveal, value: deletions.offer)
    }

    /// How long the bar stays in each state; nil while Undo runs.
    private static func shownFor(_ state: Deletions.Offer.State) -> Double? {
        switch state {
        case .offered: 8
        case .undoing: nil
        case .undone: 3
        case .failed: 8
        }
    }

    private func bar(_ offer: Deletions.Offer) -> some View {
        let shape = RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
        return HStack(spacing: QBankSpacing.space3) {
            Image(systemName: icon(offer.state))
                .foregroundStyle(.qbank(tone(offer.state)))
                .accessibilityHidden(true)
            Text(line(offer))
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(offer.state.isFailure ? .wrong : .text1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("undo.line")
            switch offer.state {
            case .offered:
                Button("Undo") {
                    Task { await deletions.undo(with: app) }
                }
                .buttonStyle(.qbank(.secondary, size: .small))
                .accessibilityIdentifier("undo.button")
            case .undoing:
                ProgressView()
                    .frame(minWidth: 44, minHeight: 32)
            case .undone, .failed:
                EmptyView()
            }
        }
        .padding(.leading, QBankSpacing.space4)
        .padding(.trailing, QBankSpacing.space3)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(shape.fill(.qbank(.surfaceRaised)))
        .qbankElevation(.popover, in: shape)
        .screenColumn()
        .padding(.bottom, QBankSpacing.space3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo.bar")
        .onAppear {
            AccessibilityNotification.Announcement(line(offer)).post()
        }
    }

    private func line(_ offer: Deletions.Offer) -> String {
        switch offer.state {
        case .offered, .undoing: offer.line
        case .undone: offer.back
        case .failed(let message): message
        }
    }

    private func icon(_ state: Deletions.Offer.State) -> String {
        switch state {
        case .offered, .undoing: "trash"
        case .undone: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    private func tone(_ state: Deletions.Offer.State) -> QBankColorToken {
        switch state {
        case .offered, .undoing: .text2
        case .undone: .correct
        case .failed: .wrong
        }
    }
}

private extension Deletions.Offer.State {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
