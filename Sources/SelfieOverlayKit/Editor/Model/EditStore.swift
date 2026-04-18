import Combine
import Foundation

/// Observable wrapper around a `Timeline` value. Each call to `apply(_:name:)`
/// swaps in a new timeline and registers an undo action that restores the
/// previous value. Because `Timeline` is a pure value type, undo and redo
/// simply swap whole snapshots — no diffing, no partial rollbacks.
public final class EditStore: ObservableObject {

    @Published public private(set) var timeline: Timeline
    public let undoManager: UndoManager

    public init(timeline: Timeline, undoManager: UndoManager = UndoManager()) {
        self.timeline = timeline
        self.undoManager = undoManager
    }

    /// Replace the current timeline with the result of `mutation`. Registers
    /// an undo action that restores the pre-mutation snapshot. No-ops when
    /// the mutation returns an identical timeline.
    public func apply(name: String? = nil, _ mutation: (Timeline) -> Timeline) {
        let previous = timeline
        let next = mutation(previous)
        guard next != previous else { return }
        swap(to: next, previous: previous, name: name)
    }

    /// Convenience: replace the timeline wholesale. Useful for tests and for
    /// the `from project` seed flow.
    public func replace(with timeline: Timeline, name: String? = nil) {
        apply(name: name) { _ in timeline }
    }

    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }

    private func swap(to next: Timeline, previous: Timeline, name: String?) {
        timeline = next
        undoManager.registerUndo(withTarget: self) { store in
            // Inverse swap — registers redo against the undo stack too.
            store.swap(to: previous, previous: next, name: name)
        }
        if let name {
            undoManager.setActionName(name)
        }
    }
}
