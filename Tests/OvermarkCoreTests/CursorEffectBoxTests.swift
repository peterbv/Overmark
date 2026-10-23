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

    @Test func trailOnlyAppendsWhileLaserIsOn() {
        var effects = CursorEffects()
        let box = CursorEffectBox()
        box.updateEffects(effects)
        box.updateCursor(Point(x: 1, y: 1))
        #expect(box.current().laserTrail.isEmpty)

        effects.isLaserEnabled = true
        box.updateEffects(effects)
        let sample = Point(x: 5, y: 6)
        box.updateCursor(sample)
        let frame = box.current()
        #expect(frame.laserTrail.count == 1)
        #expect(frame.laserTrail.first?.point == sample)
    }

    @Test func trailPrunesStaleSamplesAndCaps() {
        var effects = CursorEffects()
        effects.isLaserEnabled = true
        let box = CursorEffectBox()
        box.updateEffects(effects)

        let now = Date()
        // A sample from before the glow window: the fresh append prunes it.
        box.updateCursor(Point(x: -9, y: -9), at: now.addingTimeInterval(-CursorEffectBox.trailWindow - 1))
        box.updateCursor(Point(x: 1, y: 1), at: now)
        #expect(box.current().laserTrail.count == 1)

        for index in 0..<(CursorEffectBox.trailCapacity + 3) {
            box.updateCursor(Point(x: Double(index), y: 0), at: now.addingTimeInterval(Double(index) * 0.001))
        }
        let trail = box.current().laserTrail
        #expect(trail.count == CursorEffectBox.trailCapacity)
        #expect(trail.last?.point.x == Double(CursorEffectBox.trailCapacity + 2))
    }

    @Test func turningLaserOffClearsTheTrailAndNilCursorForgetsIt() {
        var effects = CursorEffects()
        effects.isLaserEnabled = true
        let box = CursorEffectBox()
        box.updateEffects(effects)
        box.updateCursor(Point(x: 2, y: 2))
        #expect(!box.current().laserTrail.isEmpty)

        // Track loss (nil position) also drops the trail: a tail pointing
        // nowhere is worse than none.
        box.updateCursor(nil)
        #expect(box.current().laserTrail.isEmpty)

        box.updateCursor(Point(x: 3, y: 3))
        effects.isLaserEnabled = false
        box.updateEffects(effects)
        #expect(box.current().laserTrail.isEmpty)
        #expect(box.current().cursor == Point(x: 3, y: 3))
    }

    @Test func laserFlagsInBurnableContent() {
        var effects = CursorEffects()
        effects.isLaserEnabled = true
        #expect(CursorEffectFrame(effects: effects).hasBurnableContent)

        let withTrail = CursorEffectFrame(laserTrail: [LaserSample(point: Point(x: 0, y: 0))])
        #expect(withTrail.hasBurnableContent)
    }
}
