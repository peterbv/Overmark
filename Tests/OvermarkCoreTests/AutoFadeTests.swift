import Testing
import Foundation
@testable import OvermarkCore

@Suite("Auto-fade and in-place edits")
struct AutoFadeTests {
    /// A minimal annotation of the given tool: a short horizontal stroke.
    private func makeAnnotation(_ tool: AnnotationTool) -> Annotation {
        var annotation = Annotation(
            tool: tool,
            color: .red,
            lineWidth: 4,
            path: [
                Point(x: 10, y: 10),
                Point(x: 40, y: 10)
            ],
            bounds: Rect(
                origin: Point(x: 0, y: 0),
                size: Size(width: 50, height: 20)
            )
        )
        if tool == .text {
            annotation.text = "hola"
        }
        return annotation
    }

    @Test("Step numbers are excluded from the fade timer")
    func stepNumbersNeverFade() {
        #expect(makeAnnotation(.pen).isFadeable)
        #expect(makeAnnotation(.rectangle).isFadeable)
        #expect(makeAnnotation(.ellipse).isFadeable)
        #expect(makeAnnotation(.text).isFadeable)
        #expect(makeAnnotation(.highlighter).isFadeable)
        #expect(makeAnnotation(.arrow).isFadeable)
        #expect(makeAnnotation(.line).isFadeable)

        #expect(!makeAnnotation(.stepNumber).isFadeable)
        //_annotations that never reach the document in the first place
        #expect(!makeAnnotation(.laserPointer).isFadeable)
        #expect(!makeAnnotation(.blur).isFadeable)
        #expect(!makeAnnotation(.spotlight).isFadeable)
    }

    @Test("Updating without history keeps undo empty")
    func updateWithoutHistoryIsStateless() {
        let pen = makeAnnotation(.pen)
        // Built with the annotation already in it: no add, no history.
        var document = AnnotationDocument(annotations: [pen])

        var faded = pen
        faded.opacity = 0.6
        document.update(faded, recordHistory: false)

        #expect(document.annotations.first?.opacity == 0.6)
        #expect(!document.canUndo)
        #expect(!document.canRedo)
    }

    @Test("Recording history still works for user edits")
    func updateWithHistoryIsUndoable() {
        let pen = makeAnnotation(.pen)
        var document = AnnotationDocument(annotations: [pen])

        document.update(pen)
        #expect(document.canUndo)
    }

    @Test("Removing without history leaves no undo trail")
    func removeWithoutHistoryIsStateless() {
        let pen = makeAnnotation(.pen)
        var document = AnnotationDocument(annotations: [pen])

        document.remove(id: pen.id, recordHistory: false)
        #expect(document.annotations.isEmpty)
        #expect(!document.canUndo)
    }

    @Test("Fade defaults live in ToolSettings")
    func toolSettingsFadeDefaults() {
        #expect(ToolSettings().autoFadeSeconds == 0)
        var settings = ToolSettings()
        settings.autoFadeSeconds = 10
        #expect(settings.autoFadeSeconds == 10)
    }

    @Test("Ring and ripple defaults land in CursorEffects")
    func cursorEffectsPolishDefaults() {
        let effects = CursorEffects()
        #expect(effects.highlightShape == .circle)
        #expect(effects.highlightBorderWidth == 3)
        #expect(effects.highlightFillOpacity == 0.35)
        #expect(effects.isClickAnimationEnabled)

        #expect(HighlightShape.allCases.count == 3)
    }
}
