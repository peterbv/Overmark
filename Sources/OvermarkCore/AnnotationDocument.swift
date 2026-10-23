import Foundation

/// The set of annotations on the canvas, plus the undo/redo history.
///
/// `AnnotationDocument` is a value type. The canvas renders it, the user
/// mutates it by producing new copies, and undo/redo is handled by two stacks
/// of previous states — one to undo from, one to redo from.
public struct AnnotationDocument: Hashable, Sendable, Codable {
    /// Maximum number of undo steps retained.
    public static let historyLimit = 100

    public private(set) var annotations: [Annotation]

    /// Previous states, newest last. Undo pops from here.
    private var undoStack: [[Annotation]]
    /// Undone states, newest last. Redo pops from here.
    private var redoStack: [[Annotation]]

    public init(annotations: [Annotation] = []) {
        self.annotations = annotations
        self.undoStack = []
        self.redoStack = []
    }

    public var isEmpty: Bool { annotations.isEmpty }
    public var count: Int { annotations.count }

    /// Whether an undo is currently available.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Whether a redo is currently available.
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The next step number to stamp.
    ///
    /// The number is derived from the annotations that are present rather than
    /// kept in a separate counter, so it stays correct after an undo, a redo
    /// or a cleared document. Without this, every step would be stamped "1".
    public var nextStepNumber: Int {
        annotations.compactMap(\.stepNumber).max().map { $0 + 1 } ?? 1
    }

    /// Appends an annotation and records the previous state for undo.
    public mutating func add(_ annotation: Annotation) {
        recordHistory()
        annotations.append(annotation)
    }

    /// Removes the annotation with the given id, if present.
    ///
    /// `recordHistory: false` is for stateless removals — the auto-erase
    /// timer takes drawings away on its own, which is not a user action and
    /// should not be undoable.
    @discardableResult
    public mutating func remove(
        id: Annotation.ID,
        recordHistory shouldRecord: Bool = true
    ) -> Annotation? {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        if shouldRecord {
            recordHistory()
        }
        return annotations.remove(at: index)
    }

    /// Replaces the annotation with the matching id.
    ///
    /// `recordHistory: false` is for animated, stateless changes: the
    /// auto-erase fade pushes a handful of opacity nudges, and none of
    /// those intermediate frames should be undoable.
    public mutating func update(
        _ annotation: Annotation,
        recordHistory shouldRecord: Bool = true
    ) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        if shouldRecord {
            recordHistory()
        }
        annotations[index] = annotation
    }

    /// Replaces every annotation with a matching id, recording one history
    /// entry for the whole batch.
    ///
    /// Selection gestures commit this way: dragging five marks around is one
    /// user action, so one undo step must bring all five back. The order of
    /// `annotations` is preserved — replacements happen in place instead of
    /// reshuffling — because painting order is the z-order the user drew in.
    /// Returns `true` when at least one annotation was replaced.
    @discardableResult
    public mutating func update(
        _ newAnnotations: [Annotation],
        recordHistory shouldRecord: Bool = true
    ) -> Bool {
        var replaced = false
        for annotation in newAnnotations {
            guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else {
                continue
            }
            if !replaced, shouldRecord {
                recordHistory()
            }
            annotations[index] = annotation
            replaced = true
        }
        return replaced
    }

    /// Removes the annotations with the given ids, recording one history
    /// entry for the whole batch.
    ///
    /// `recordHistory: false` keeps parity with the single-annotation
    /// removal: stateless removals (the auto-erase timer) never pick this
    /// path, but the flag keeps the batch symmetric with `update`.
    /// Returns the annotations that were actually removed.
    @discardableResult
    public mutating func remove(
        ids: Set<Annotation.ID>,
        recordHistory shouldRecord: Bool = true
    ) -> [Annotation] {
        guard !ids.isEmpty else { return [] }
        let removed = annotations.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        if shouldRecord {
            recordHistory()
        }
        annotations.removeAll { ids.contains($0.id) }
        return removed
    }

    /// Removes every annotation.
    public mutating func removeAll() {
        guard !annotations.isEmpty else { return }
        recordHistory()
        annotations.removeAll()
    }

    /// Reverts the most recent change.
    ///
    /// Returns `true` when an undo was performed.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    /// Re-applies the most recently undone change.
    ///
    /// Returns `true` when a redo was performed.
    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        return true
    }

    /// Pushes the current state onto the undo stack.
    ///
    /// Any pending redo is discarded, because a fresh edit means the user has
    /// abandoned the branch they had undone.
    private mutating func recordHistory() {
        redoStack.removeAll()
        undoStack.append(annotations)
        if undoStack.count > Self.historyLimit {
            undoStack.removeFirst()
        }
    }

    // MARK: - Codable

    /// Only the annotations are persisted; undo history is session-scoped.
    private enum CodingKeys: String, CodingKey {
        case annotations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        annotations = try container.decode([Annotation].self, forKey: .annotations)
        undoStack = []
        redoStack = []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(annotations, forKey: .annotations)
    }
}

