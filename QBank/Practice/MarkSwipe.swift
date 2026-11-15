import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tells a swipe that marks words from one that scrolls the question, with no hold first.
///
/// Marking runs along a line and scrolling runs up and down, so a finger's direction decides: a
/// swipe that starts on words and sets off mostly sideways marks, and one that sets off up or down
/// scrolls. The Apple Pencil and the mouse mark in any direction, as a real highlighter is drawn.
/// A swipe that starts beside the words always scrolls, and so do two fingers.
nonisolated enum MarkSwipe {
    /// What touches the screen.
    enum Pointer: Equatable, Sendable {
        case finger
        case pencil
        case mouse

        init(_ type: UITouch.TouchType) {
            switch type {
            case .pencil: self = .pencil
            case .indirectPointer: self = .mouse
            default: self = .finger
            }
        }

        /// How far it travels before the swipe is read. A finger takes what a scroll takes to start;
        /// the Pencil's tip and the mouse are steadier, so they take less.
        var slop: CGFloat {
            switch self {
            case .finger: 10
            case .pencil, .mouse: 4
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        /// Too little travel to tell. A touch that ends here was a tap.
        case undecided
        case marks
        case scrolls
    }

    /// The steepest a finger's swipe can set off and still mark: 35 degrees off the line of text.
    static let steepest = 0.7

    /// Reads a swipe from where it started and how far it has gone. Once it says marks or scrolls,
    /// that holds for the rest of the gesture, wherever the swipe goes next.
    /// - Parameters:
    ///   - onWords: the swipe started on the question's words, not beside them.
    ///   - fingers: how many fingers are on the screen.
    ///   - travel: how far it has gone from where it started.
    static func verdict(pointer: Pointer, onWords: Bool, fingers: Int, travel: CGSize) -> Verdict {
        guard onWords else { return .scrolls }
        if pointer == .finger, fingers > 1 { return .scrolls }
        guard hypot(travel.width, travel.height) >= pointer.slop else { return .undecided }
        if pointer != .finger { return .marks }
        return abs(travel.height) <= abs(travel.width) * steepest ? .marks : .scrolls
    }
}

/// Begins as soon as a swipe reads as marking, and fails as soon as it reads as scrolling, so the
/// scroll view, which waits for it, takes the swipe from there.
final class MarkSwipeRecognizer: UIGestureRecognizer {
    /// Whether a point of the view is on words.
    var isOnWords: (CGPoint) -> Bool = { _ in true }
    /// Where the swipe started, in the view.
    private(set) var start = CGPoint.zero

    private var tracked: UITouch?
    private var startInWindow = CGPoint.zero
    private var startedOnWords = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, touches.count == 1, let touch = touches.first else {
            // Another finger came down on the words before the swipe was read.
            if state == .possible { state = .failed }
            return
        }
        tracked = touch
        start = touch.location(in: view)
        startInWindow = touch.location(in: nil)
        startedOnWords = isOnWords(start)
        read(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        if state == .possible {
            read(tracked, event)
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        startedOnWords = false
    }

    private func read(_ touch: UITouch, _ event: UIEvent) {
        // Measured on the screen, so a page still gliding to a stop does not count as travel.
        let now = touch.location(in: nil)
        let fingers = event.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? 1
        let verdict = MarkSwipe.verdict(
            pointer: MarkSwipe.Pointer(touch.type),
            onWords: startedOnWords,
            fingers: fingers,
            travel: CGSize(width: now.x - startInWindow.x, height: now.y - startInWindow.y)
        )
        switch verdict {
        case .undecided: break
        case .marks: state = .began
        case .scrolls: state = .failed
        }
    }
}
