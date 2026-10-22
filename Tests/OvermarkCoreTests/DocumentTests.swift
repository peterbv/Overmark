import Foundation
import Testing
@testable import OvermarkCore

// MARK: - Undo / redo

@Suite("AnnotationDocument")
struct AnnotationDocumentTests {
    @Test("A new document has nothing to undo")
    func emptyDocument() {
        let document = AnnotationDocument()

        #expect(document.isEmpty)
        #expect(!document.canUndo)
        #expect(!document.canRedo)
    }

    @Test("Undo removes the last annotation")
    func undo() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))
        document.add(Annotation(tool: .rectangle))

        #expect(document.count == 2)

        let undone = document.undo()
        #expect(undone)
        #expect(document.count == 1)
        #expect(document.canRedo)
    }

    @Test("Redo restores the undone annotation")
    func redo() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))
        document.add(Annotation(tool: .rectangle))
        document.undo()

        let redone = document.redo()
        #expect(redone)
        #expect(document.count == 2)
    }

    @Test("Undoing everything reports failure")
    func undoExhausted() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))

        let first = document.undo()
        let second = document.undo()

        #expect(first)
        #expect(!second)
    }

    @Test("A new edit discards the redo branch")
    func redoClearedByEdit() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))
        document.add(Annotation(tool: .rectangle))
        document.undo()

        #expect(document.canRedo)

        document.add(Annotation(tool: .ellipse))

        #expect(!document.canRedo)
    }

    @Test("Removing all annotations is undoable")
    func removeAll() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))
        document.removeAll()

        #expect(document.isEmpty)
        #expect(document.canUndo)

        document.undo()
        #expect(document.count == 1)
    }

    @Test("The history is bounded")
    func historyLimit() {
        var document = AnnotationDocument()
        for index in 0..<(AnnotationDocument.historyLimit + 20) {
            document.add(Annotation(tool: .pen, text: "\(index)"))
        }

        // Undoing is limited to the retained history.
        var undone = 0
        while document.undo() {
            undone += 1
        }

        #expect(undone == AnnotationDocument.historyLimit)
    }

    @Test("Encoding persists the annotations but not the history")
    func codable() throws {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen, text: "hello"))
        document.undo()
        document.add(Annotation(tool: .arrow, text: "world"))

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)

        #expect(decoded.count == 1)
        #expect(decoded.annotations.first?.text == "world")
        #expect(!decoded.canUndo)
    }
}

// MARK: - Step numbering

@Suite("Step numbering")
struct StepNumberingTests {
    /// Builds a step-number annotation carrying the given number.
    private func step(_ number: Int) -> Annotation {
        Annotation(tool: .stepNumber, stepNumber: number)
    }

    @Test("An empty document starts at one")
    func emptyDocumentStartsAtOne() {
        #expect(AnnotationDocument().nextStepNumber == 1)
    }

    @Test("Step numbers increase as annotations are added")
    func increasesWithAnnotations() {
        var document = AnnotationDocument()
        document.add(step(1))
        #expect(document.nextStepNumber == 2)

        document.add(step(2))
        #expect(document.nextStepNumber == 3)
    }

    @Test("Annotations without a step number do not affect the counter")
    func otherToolsDoNotCount() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .pen))
        document.add(Annotation(tool: .text, text: "hello"))

        #expect(document.nextStepNumber == 1)
    }

    @Test("Undoing a step rewinds the counter")
    func undoRewindsCounter() {
        var document = AnnotationDocument()
        document.add(step(1))
        document.add(step(2))

        document.undo()

        #expect(document.nextStepNumber == 2)
    }

    @Test("Clearing the document resets the counter")
    func clearResetsCounter() {
        var document = AnnotationDocument()
        document.add(step(1))
        document.add(step(2))
        document.removeAll()

        #expect(document.nextStepNumber == 1)
    }
}

// MARK: - Permissions

@Suite("PermissionState")
struct PermissionStateTests {
    @Test("Outstanding permissions are listed screen recording first")
    func outstandingOrder() {
        let state = PermissionState(
            screenRecording: .notDetermined,
            accessibility: .notDetermined
        )

        #expect(state.outstanding == [.screenRecording, .accessibility])
    }

    @Test("A fully granted state has nothing outstanding")
    func fullyGranted() {
        let state = PermissionState(
            screenRecording: .granted,
            accessibility: .granted
        )

        #expect(state.isFullyGranted)
        #expect(state.outstanding.isEmpty)
    }

    @Test("A denied permission needs attention")
    func deniedNeedsAttention() {
        #expect(PermissionStatus.denied.needsAttention)
        #expect(!PermissionStatus.granted.needsAttention)
    }
}
