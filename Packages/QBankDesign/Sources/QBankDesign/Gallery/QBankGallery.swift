#if canImport(SwiftUI)
import SwiftUI

/// Every component on one screen, laid out like the approved wireframes
/// (Home, Course, Settings, the runner footer). Used by previews and rendered screenshots.
struct QBankGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.gapSection) {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                Text("Home").qbankFont(.largeTitle).foregroundStyle(.qbank(.text1))
                QBankSectionHeader("Semester 1").padding(.horizontal, QBankSpacing.space5)
                Button {
                } label: {
                    VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NURS 406").qbankFont(.footnote, weight: .semibold).foregroundStyle(.qbank(.tint))
                            Text("Mental Health").qbankFont(.headline)
                        }
                        HStack(spacing: QBankSpacing.space4) {
                            Text("86 questions · 3 weeks").qbankFont(.footnote).foregroundStyle(.qbank(.text2))
                            QBankTintedLabel("12 to review", systemImage: "tray", size: .small)
                        }
                        QBankProgressPill(value: 0.41)
                    }
                }
                .buttonStyle(.qbankCard)
            }

            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                QBankSectionHeader("Week 2").padding(.horizontal, QBankSpacing.space5)
                QBankTintedLabel("Exam bank · 17 questions", tone: .neutral, style: .outline, size: .small)
                QBankListGroup {
                    Button {
                    } label: {
                        QBankListRow(
                            "Therapeutic Communication and the Relationship",
                            detail: "9 of 14 answered",
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.qbankRow)
                    QBankListRow(
                        "Psychosocial Assessment and Safety Screening",
                        detail: "Replaced Oct 6 · 12 questions",
                        accessibilityChildren: .contain
                    ) {
                        Button {
                        } label: {
                            Label("Restore", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.qbank(.secondary, size: .small))
                    }
                }
            }

            QBankListGroup(header: "Review") {
                QBankListRow("Refusal after involuntary admission", detail: "Week 1 · Single answer") {
                    QBankStatusMark(.wrong, variant: .pill, size: .small)
                }
                QBankListRow("Priority with vital signs", detail: "Week 3 · Priority") {
                    QBankStatusMark(.partial, variant: .pill, size: .small)
                }
                QBankListRow("Lithium toxicity cues", detail: "Week 3 · Select all") {
                    QBankStatusMark(.guessed, variant: .pill, size: .small)
                }
            }

            QBankListGroup(header: "Look", footer: "Match device follows this device's light or dark setting.") {
                QBankSegmentedControl(
                    "Look", selection: .constant("auto"),
                    options: [
                        .init("auto", "Match device"),
                        .init("light", "Light"),
                        .init("dark", "Dark"),
                    ]
                )
                .padding(QBankSpacing.space3)
            }

            VStack(alignment: .leading, spacing: QBankSpacing.gapStack) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        QBankStatusMark(.correct)
                        Spacer()
                        QBankTimerPill(secondsRemaining: 758)
                        QBankTimerPill(secondsRemaining: 245)
                    }
                    VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                        QBankStatusMark(.correct)
                        QBankTimerPill(secondsRemaining: 758)
                        QBankTimerPill(secondsRemaining: 245)
                    }
                }
                QBankProgressBar(value: 3.0 / 17, accessibilityTitle: "Question 3 of 17")
                Button("Check answer") {}
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                HStack(spacing: QBankSpacing.space3) {
                    Button("Skip for now") {}.buttonStyle(.qbank(.quiet, fullWidth: true))
                    Button("End exam") {}.buttonStyle(.qbank(.destructive, fullWidth: true))
                }
            }
        }
        .padding(QBankSpacing.gutterPhone)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(.bg))
    }
}

#Preview("Gallery, light") {
    ScrollView { QBankGallery() }
        .qbankScreenBackground()
        .preferredColorScheme(.light)
}

#Preview("Gallery, dark") {
    ScrollView { QBankGallery() }
        .qbankScreenBackground()
        .preferredColorScheme(.dark)
}

#Preview("Gallery, every palette") {
    ScrollView {
        ForEach(QBankPalette.allCases) { palette in
            QBankGallery().qbankPalette(palette)
        }
    }
    .qbankScreenBackground()
}
#endif
