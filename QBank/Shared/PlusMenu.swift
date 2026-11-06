import SwiftUI

extension View {
    /// Puts a screen's + menu at the top right, while the screen is on screen. A toolbar menu left
    /// on a screen with another pushed over it kept the signed-in screens from going at sign-out,
    /// so signing in again brought them back as they were.
    func plusMenu(_ isShown: Bool, @ViewBuilder menu: () -> some View) -> some View {
        plusMenu(isShown, more: false, menu: menu) { EmptyView() }
    }

    /// Puts a screen's More menu, a `MoreMenu`, by itself at the top right, the same way.
    func moreMenu(_ isShown: Bool, @ViewBuilder menu: () -> some View) -> some View {
        plusMenu(false, more: isShown, menu: { EmptyView() }, more: menu)
    }

    /// Puts More and + at the top right, the same way. More is the first trailing item, so it sits
    /// just left of +.
    func plusMenu(_ isShown: Bool, more showsMore: Bool, @ViewBuilder menu: () -> some View, @ViewBuilder more: () -> some View) -> some View {
        modifier(TopBarMenus(showsAdd: isShown, showsMore: showsMore, add: menu(), more: more()))
    }

    /// Puts More and a plain + at the top right, the same way, for a screen with one way to add: the
    /// + does it at once, with no menu of one row. Its button is named for what it does.
    func plusButton(
        _ isShown: Bool,
        label: String,
        identifier: String,
        isEnabled: Bool,
        more showsMore: Bool,
        action: @escaping () -> Void,
        @ViewBuilder more: () -> some View
    ) -> some View {
        plusMenu(isShown, more: showsMore) {
            Button(action: action) {
                Image(systemName: "plus")
            }
            .disabled(!isEnabled)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        } more: {
            more()
        }
    }
}

/// More, an ellipsis at the top right: what a screen offers besides adding. The menu has no
/// heading. Its button is named "More for" what the screen shows, such as "More for Exam 1".
struct MoreMenu<Items: View>: View {
    let name: String
    let identifier: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More for \(name)")
        .accessibilityIdentifier(identifier)
    }
}

/// On iOS 26 a fixed spacer keeps More and + each its own circle, the same glass as the back
/// button, instead of one shared pill.
private struct TopBarMenus<Add: View, More: View>: ViewModifier {
    let showsAdd: Bool
    let showsMore: Bool
    let add: Add
    let more: More
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isOnScreen {
                    if showsMore {
                        ToolbarItem(placement: .topBarTrailing) {
                            more
                        }
                    }
                    if showsMore, showsAdd, #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    if showsAdd {
                        ToolbarItem(placement: .topBarTrailing) {
                            add
                        }
                    }
                }
            }
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
    }
}
