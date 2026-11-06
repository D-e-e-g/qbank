import Observation
import QBankDesign
import QBankKit
import SwiftUI

/// The admin's look at a user account: every screen as the user sees it, with every control that
/// would change something answering with one short note and sending nothing. The account is the one
/// chosen on the web, and QBank refuses the admin's writes whatever this phone sends.
@Observable
final class FrozenView {
    /// True while the admin is signed in. A user account's controls just do what they say.
    var isOn = false {
        didSet {
            if !isOn {
                email = nil
                noteID = nil
            }
        }
    }
    /// The email of the account on screen. Nil until QBank says, and without a connection.
    private(set) var email: String?
    /// Changes each time the note is asked for, so a second tap shows it for its full time again.
    private(set) var noteID: UUID?
    /// True while a runner covers the tabs, so only its note shows, not the one under it as well.
    fileprivate(set) var isRunnerOpen = false

    /// The one note every control answers with, the same as on the web.
    var note: String {
        "This is a frozen view of \(email ?? "a user account"). Nothing here can be changed."
    }

    /// The thin line that says whose account is on screen, in the note's words.
    var line: String? {
        guard isOn, let email else { return nil }
        return "Frozen view of \(email)"
    }

    /// Does what a control does, or in the frozen view answers with the note instead.
    func perform(_ action: () -> Void) {
        if !refuses() {
            action()
        }
    }

    /// True in the frozen view, having answered with the note. What would change something asks
    /// this first, so it sends nothing.
    func refuses() -> Bool {
        guard isOn else { return false }
        showNote()
        return true
    }

    func showNote() {
        noteID = UUID()
        AccessibilityNotification.Announcement(note).post()
    }

    func hideNote() {
        noteID = nil
    }

    /// Reads whose account is on screen. A failed read keeps the name it had.
    func readAccount(with client: QBankClient) async {
        guard isOn, let list = try? await client.students(), isOn else { return }
        email = list.viewing?.email
    }
}

extension View {
    /// The note over the bottom of a tab, for a few seconds.
    func frozenNote(_ frozen: FrozenView) -> some View {
        overlay(alignment: .bottom) {
            if !frozen.isRunnerOpen {
                FrozenNoteBar(frozen: frozen)
            }
        }
    }

    /// The note over a runner, which covers the tabs. `clearing` keeps it above the runner's footer.
    func frozenRunnerNote(_ frozen: FrozenView, clearing: CGFloat) -> some View {
        overlay(alignment: .bottom) {
            FrozenNoteBar(frozen: frozen)
                .padding(.bottom, clearing)
        }
        .onAppear { frozen.isRunnerOpen = true }
        .onDisappear { frozen.isRunnerOpen = false }
    }

    /// For a control the user's state leaves disabled, such as Start exam with nothing ticked: it
    /// looks the same, and in the frozen view a tap on it answers with the note too.
    func answersWhenFrozen(_ frozen: FrozenView) -> some View {
        overlay {
            if frozen.isOn {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { frozen.showNote() }
            }
        }
    }
}

/// The note, drawn as the Undo bar is. Tapping it puts it away early.
private struct FrozenNoteBar: View {
    let frozen: FrozenView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let id = frozen.noteID {
                bar
                    .task(id: id) {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, frozen.noteID == id else { return }
                        frozen.hideNote()
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : QBankMotion.reveal, value: frozen.noteID == nil)
    }

    private var bar: some View {
        let shape = RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
        return HStack(spacing: QBankSpacing.space3) {
            Image(systemName: "snowflake")
                .foregroundStyle(.qbank(.text2))
                .accessibilityHidden(true)
            Text(frozen.note)
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(.text1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("frozen.note")
        }
        .padding(.horizontal, QBankSpacing.space4)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(shape.fill(.qbank(.surfaceRaised)))
        .qbankElevation(.popover, in: shape)
        .contentShape(shape)
        .onTapGesture { frozen.hideNote() }
        .screenColumn()
        .padding(.bottom, QBankSpacing.space3)
        .accessibilityElement(children: .contain)
    }
}

/// The thin line that says whose account is on screen. It sits in the room the status bar leaves
/// above the navigation bar, so nothing under it moves. Where there is no such room, as on a
/// sideways iPhone or one whose clock sits in the middle, it does not show; the note still names
/// the account.
struct FrozenLine: View {
    let frozen: FrozenView

    /// Taller than a home-button iPhone's status bar, whose clock sits where this line would. An
    /// iPad's clock sits at the side, so its bar is room enough whenever it shows.
    private static var needsMoreThan: CGFloat { Device.isPad ? 0 : 24 }

    var body: some View {
        GeometryReader { proxy in
            let room = proxy.safeAreaInsets.top
            if let line = frozen.line, room > Self.needsMoreThan {
                Text(line)
                    .qbankFont(.caption2, weight: .medium)
                    .foregroundStyle(.qbank(.text3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, QBankSpacing.space5)
                    .frame(maxWidth: .infinity)
                    .frame(height: room, alignment: .bottom)
                    .offset(y: -room)
                    .accessibilityIdentifier("frozen.line")
            }
        }
        .allowsHitTesting(false)
    }
}
