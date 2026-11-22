import QBankDesign
import QBankKit
import SwiftUI
import UniformTypeIdentifiers

/// A section's uppercase header, with an optional action at its right, such as New or Edit.
struct SectionHead: View {
    let title: String
    var action: String?
    /// What VoiceOver reads for the action, which sits apart from the header: "New page".
    var label: String?
    var identifier = ""
    var isEnabled = true
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            QBankSectionHeader(title)
            Spacer(minLength: QBankSpacing.space3)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.qbank(.plain, size: .small))
                    .disabled(!isEnabled)
                    .accessibilityLabel(label ?? action)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(.leading, QBankSpacing.space5)
        .padding(.trailing, QBankSpacing.space1)
    }
}

/// How far she is, at a row's right edge: Done, "22 of 27", or Not started.
struct ProgressState: View {
    let progress: FolderProgress

    var body: some View {
        let text = FolderWording.state(progress)
        if !text.isEmpty {
            Text(text)
                .qbankFont(.footnote, weight: progress.state == .fresh ? .medium : .semibold)
                .monospacedDigit()
                .foregroundStyle(.qbank(color))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var color: QBankColorToken {
        switch progress.state {
        case .done: .correct
        case .fresh: .text3
        case .started: .text1
        }
    }
}

/// A page on the course page: its name with its badge, its folders and questions, how far she is,
/// and a chevron to open it.
struct ExamPageRow: View {
    let page: ExamPage

    var body: some View {
        QBankListRow(
            page.exam.name, tag: page.exam.badge.map(Wording.badge), detail: FolderWording.pageRow(page),
            systemImage: "square.stack.3d.up", showsChevron: true
        ) {
            ProgressState(progress: page.progress)
        }
    }
}

/// A folder in a list: its name, its sets and how far she is, and a chevron to open it.
struct FolderRow: View {
    let folder: Folder

    var body: some View {
        QBankListRow(folder.name, detail: FolderWording.meta(folder), systemImage: "folder", showsChevron: true) {
            ProgressState(progress: FolderProgress(folder))
        }
    }
}

/// Folders as rows that open each one. While she edits the order, each row has a grip to drag it
/// and up and down buttons, as the design system orders things on touch and with VoiceOver.
struct FolderList: View {
    let folders: [Folder]
    /// Her order while she edits it, or nil.
    @Binding var order: [String]?
    /// The folder she lifted last. SwiftUI can ask a row for its drag item again after the drop,
    /// so this alone does not say a drag is under way.
    @State private var dragging: String?
    /// The rows a drag is over now: empty once it drops or leaves the list.
    @State private var hovered: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        QBankListGroup {
            if let order {
                ForEach(Array(order.enumerated()), id: \.element) { position, id in
                    if let folder = folders.first(where: { $0.id == id }) {
                        ReorderRow(
                            folder: folder,
                            canMoveUp: position > 0,
                            canMoveDown: position < order.count - 1,
                            move: { offset in move(id, by: offset) }
                        )
                        .opacity(!hovered.isEmpty && dragging == id ? 0.5 : 1)
                        .onDrag {
                            dragging = id
                            return NSItemProvider(object: id as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDrop(target: id, order: $order, dragging: $dragging, hovered: $hovered, reduceMotion: reduceMotion))
                    }
                }
            } else {
                ForEach(folders) { folder in
                    NavigationLink(value: CoursePage.folder(folder.id)) {
                        FolderRow(folder: folder)
                    }
                    .buttonStyle(.qbankRow)
                    .accessibilityIdentifier("folder.\(folder.name)")
                }
            }
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard var current = order, let from = current.firstIndex(of: id) else { return }
        let to = from + offset
        guard current.indices.contains(to) else { return }
        withAnimation(reduceMotion ? nil : QBankMotion.reveal) {
            current.swapAt(from, to)
            order = current
        }
    }
}

/// A folder while she puts the list in order: a grip to drag, its name, and up and down buttons.
private struct ReorderRow: View {
    let folder: Folder
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: QBankSpacing.space3) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.medium))
                .foregroundStyle(.qbank(.text3))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                QBankDetailText(FolderWording.meta(folder))
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                arrow("chevron.up", label: "Move \(folder.name) up", enabled: canMoveUp, identifier: "reorder.up.\(folder.name)") { move(-1) }
                arrow("chevron.down", label: "Move \(folder.name) down", enabled: canMoveDown, identifier: "reorder.down.\(folder.name)") { move(1) }
            }
        }
        .padding(.leading, QBankSpacing.rowPaddingHorizontal)
        .padding(.trailing, QBankSpacing.space2)
        .padding(.vertical, 6)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reorder.\(folder.name)")
    }

    private func arrow(_ systemImage: String, label: String, enabled: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .foregroundStyle(.qbank(enabled ? .tint : .text4))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Moves a dragged folder to where another one is as she drags over it, moving the rest down.
private struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var order: [String]?
    @Binding var dragging: String?
    @Binding var hovered: Set<String>
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        hovered.insert(target)
        guard let dragging, dragging != target, var current = order,
            let from = current.firstIndex(of: dragging), let to = current.firstIndex(of: target)
        else { return }
        withAnimation(reduceMotion ? nil : QBankMotion.reveal) {
            current.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            order = current
        }
    }

    func dropExited(info: DropInfo) {
        hovered.remove(target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hovered = []
        return true
    }
}
