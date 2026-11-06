import QBankDesign
import QBankKit
import SwiftUI

/// Review: the filters, Practice these N (shuffled), every question in the list with its mark,
/// and Clear the review list, which asks first. A row practices just that question.
struct ReviewView: View {
    @State private var model: ReviewModel
    @State private var practicing: PracticeRoute?
    @State private var asksToClear = false
    private let app: AppModel

    init(app: AppModel, course: CourseRef) {
        self.app = app
        _model = State(initialValue: ReviewModel(app: app, course: course))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                Text("\(Wording.name(model.course)) · what you missed or guessed")
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                if model.savedAt != nil {
                    OfflineBanner.showingSaved(phoneIsOnline: app.connection.isOnline)
                        .accessibilityIdentifier("review.offline")
                }
                if let problem = model.problem {
                    ProblemText(text: problem)
                }
                filters
                if model.selectedCount > 0 {
                    Button {
                        practicing = model.practice()
                    } label: {
                        Label("Practice these \(model.selectedCount) (shuffled)", systemImage: "shuffle")
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("review.practice")
                }
                content
            }
            .screenColumn()
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Review")
        .screenColumnTitle()
        .refreshable { await model.load() }
        .reloadsWithConnection(app) { await model.load() }
        .task { await model.load() }
        .confirmSheet(
            isPresented: $asksToClear,
            title: model.clearTitle,
            message: "Your answers and scores are kept. Only the list is emptied.",
            confirm: "Clear",
            identifier: "review.clearSheet"
        ) {
            Task { await model.clear() }
        }
        .fullScreenCover(item: $practicing, onDismiss: {
            // Answers she got fully right without guessing left the list.
            Task { await model.load() }
        }, content: { route in
            PracticeView(app: app, route: route)
        })
    }

    private var filters: some View {
        QBankSegmentedControl(
            "Review filters",
            selection: Binding(get: { model.filter }, set: { model.choose($0) }),
            options: ReviewFilter.allCases.map { .init($0, label(for: $0)) }
        )
        .accessibilityIdentifier("review.filters")
    }

    /// "All 12", "Missed 6", "Partly 3", "Guessed 3". Partly right is shortened to fit four.
    private func label(for filter: ReviewFilter) -> String {
        let word = switch filter {
        case .all: "All"
        case .missed: "Missed"
        case .partial: "Partly"
        case .guessed: "Guessed"
        }
        guard let counts = model.list?.counts else { return word }
        return "\(word) \(ReviewModel.count(of: filter, in: counts))"
    }

    @ViewBuilder
    private var content: some View {
        if model.list == nil, model.problem == nil {
            Loading(title: "Loading Review")
        } else if model.list != nil, model.questions.isEmpty {
            EmptyCard(
                message: "Questions you miss or flag as a guess show up here. They leave when you answer them fully right without guessing.",
                systemImage: "tray"
            )
        } else if !model.questions.isEmpty {
            QBankListGroup {
                ForEach(model.questions) { question in
                    Button {
                        practicing = model.practice(question)
                    } label: {
                        ReviewRow(question: question)
                    }
                    .buttonStyle(.qbankRow)
                    .accessibilityIdentifier("review.question.\(question.questionID)")
                }
            }
            if model.allCount > 0 {
                Button("Clear the review list", role: .destructive) {
                    app.frozen.perform { asksToClear = true }
                }
                .buttonStyle(.qbank(.plain))
                .foregroundStyle(.qbank(.wrong))
                .disabled(model.isClearing)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("review.clear")
            }
        }
    }
}

/// A Review question: its topic, week and format, set and when she answered, and its mark.
private struct ReviewRow: View {
    let question: ReviewQuestion

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.topic)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                    .multilineTextAlignment(.leading)
                Text("\(question.folderName) · \(question.format)")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                Text("\(question.setTitle) · \(Wording.when(question.answeredAt))")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                    .multilineTextAlignment(.leading)
                QBankStatusMark(question.mark.status, label: question.mark.label, variant: .pill, size: .small)
                    .padding(.top, QBankSpacing.space2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.qbank(.text4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, QBankSpacing.rowPaddingVertical)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
