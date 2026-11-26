import QBankDesign
import SwiftUI
import Testing
import UIKit
@testable import QBank

/// The exam's footer buttons, measured as the device draws them. A row of two large buttons is as
/// tall as one while neither label wraps.
@MainActor
@Suite("Exam answer buttons")
struct ExamAnswerButtonsTests {
    private static let oneRow = QBankButtonStyle.Size.large.minHeight
    private static let stacked = 2 * oneRow + QBankSpacing.space3

    /// The footer's width on iPhones 375, 402 and 440 points wide, and on a wide iPad.
    @Test(arguments: [343.0, 370, 408, 680], ["Submit and continue", "Finish exam"])
    func bothButtonsShareOneRowWithoutWrapping(width: Double, title: String) {
        #expect(height(title, width: width) == Self.oneRow)
    }

    /// As narrow as a zoomed iPhone's footer.
    @Test func aRowTooNarrowForBothLabelsStacksThem() {
        #expect(height("Submit and continue", width: 288) == Self.stacked)
    }

    @Test func largeTextStacksThemToo() {
        #expect(height("Submit and continue", width: 343, textSize: .xxxLarge) >= Self.stacked)
    }

    private func height(_ title: String, width: Double, textSize: DynamicTypeSize = .large) -> CGFloat {
        let buttons = ExamAnswerButtons(submitTitle: title, canSkip: true, canSubmit: true, frozen: FrozenView(), skip: {}, submit: {})
            .environment(\.dynamicTypeSize, textSize)
        return UIHostingController(rootView: buttons).sizeThatFits(in: CGSize(width: width, height: 1000)).height
    }
}
