import Foundation
import Testing
@testable import OvermarkCore

/// The safe hand-off between the app's main-actor world and the recorder's
/// frame callbacks.
@Suite("CursorEffectBox")
struct CursorEffectBoxTests {
    @Test func startsEmpty() {
        let box = CursorEffectBox()
        let frame = box.current()
        #expect(frame.cursor == nil)
        #expect(frame.clicks.isEmpty)
        #expect(!frame.hasBurnableContent)
    }

    @Test func effectUpdateKeepsCursorAndClicks() {
        let box = CursorEffectBox()
        let cursor = Point(x: 20, y: 30)
        let click = CursorClick(point: Point(x: 1, y: 2), isRight: true)
        box.updateCursor(cursor)
        box.appendClick(click)
        var effects = CursorEffects()
        effects.isHighlightEnabled = true
        box.updateEffects(effects)

        let frame = box.current()
        #expect(frame.effects.isHighlightEnabled)
        #expect(frame.cursor == cursor)
        #expect(frame.clicks == [click])
    }

    @Test func nilCursorForgetsPreviousPosition() {
        let box = CursorEffectBox()
        box.updateCursor(Point(x: 3, y: 4))
        box.updateCursor(nil)
        #expect(box.current().cursor == nil)
    }

    @Test func clicksPruneOutOfTheRippleWindow() {
        let box = CursorEffectBox()
        let now = Date()
        let fresh = CursorClick(
            point: Point(x: 1, y: 1), isRight: false,
            startedAt: now.addingTimeInterval(-0.2)
        )
        let stale = CursorClick(
            point: Point(x: 2, y: 2), isRight: false,
            startedAt: now.addingTimeInterval(-CursorEffectBox.clickWindow - 1)
        )
        box.appendClick(stale, prunedAt: now)
        box.appendClick(fresh, prunedAt: now)

        #expect(box.current().clicks == [fresh])
    }

    @Test func clicksCapKeepsTheNewest() {
        let box = CursorEffectBox()
        let now = Date()
        for index in 0..<(CursorEffectBox.clickCapacity + 2) {
            let click = CursorClick(
                point: Point(x: Double(index), y: 0), isRight: false,
                startedAt: now.addingTimeInterval(Double(index) * 0.01)
            )
            box.appendClick(click, prunedAt: now)
        }
        let clicks = box.current().clicks
        #expect(clicks.count == CursorEffectBox.clickCapacity)
        #expect(clicks.last?.point.x == Double(CursorEffectBox.clickCapacity + 1))
    }

    @Test func burnableContentFlags() {
        // Default settings enable nothing and there are no clicks.
        var effects = CursorEffects()
        #expect(!CursorEffectFrame(effects: effects).hasBurnableContent)

        effects.isSpotlightEnabled = true
        #expect(CursorEffectFrame(effects: effects).hasBurnableContent)

        effects = CursorEffects()
        let withClick = CursorEffectFrame(clicks: [CursorClick(
            point: Point(x: 0, y: 0), isRight: false
        )])
        #expect(withClick.hasBurnableContent)
    }
}
