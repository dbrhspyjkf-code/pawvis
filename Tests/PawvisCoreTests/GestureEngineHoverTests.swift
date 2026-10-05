import XCTest
@testable import PawvisCore

/// Hover anchoring: a still hand pins the cursor; the tremor moves it not
/// at all; a deliberate move breaks the pin.
final class GestureEngineHoverTests: XCTestCase {
    var engine: GestureEngine!

    override func setUp() {
        super.setUp()
        var config = GestureConfig.default
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        config.controlTrigger = .anyHand
        engine = GestureEngine(config: config)
    }

    @discardableResult
    private func feed(_ hands: [Hand], at t: TimeInterval) -> (events: [GestureEvent], overlay: OverlayState) {
        engine.process(HandFrame(time: t, hands: hands))
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap { if case .move(let to) = $0 { return to }; return nil }
    }

    func testStillHandPinsAndTremorDoesNotMove() {
        // Move, then hold still past the acquire time.
        var events: [GestureEvent] = []
        for i in 0..<30 {
            events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                           at: 0.1 + Double(i) / 30).events
        }
        // Pin acquired after 0.6 s of stillness. Now tremor: sub-radius
        // wobble in and around the rest spot.
        events = []
        for i in 0..<20 {
            let wobble = 0.010 * (i % 2 == 0 ? 1 : -1)
            events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5 + wobble, 0.7))],
                           at: 1.2 + Double(i) / 30).events
        }
        XCTAssertTrue(moves(events).isEmpty, "the tremor moves the pinned cursor not at all")
    }

    func testDeliberateMoveBreaksThePin() {
        for i in 0..<30 {
            _ = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                     at: 0.1 + Double(i) / 30)
        }
        // Pinned. A deliberate move well past the release radius follows.
        let events = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.62, 0.7))], at: 1.5)
        XCTAssertFalse(moves(events.events).isEmpty, "a deliberate move breaks the pin")
    }

    func testClicksStillLandWhilePinned() {
        for i in 0..<30 {
            _ = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                     at: 0.1 + Double(i) / 30)
        }
        // Pinned; dip to click with a tremor on the wrist.
        var events: [GestureEvent] = []
        events += feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.505, 0.7))],
                       at: 1.2).events
        events += feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.508, 0.7))],
                       at: 1.2333).events
        events += feed([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.5, 0.7))],
                       at: 1.3).events
        events += feed([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.5, 0.7))],
                       at: 1.3333).events
        let downs = events.compactMap { if case .buttonDown(.left, let at, _) = $0 { return at }; return nil }
        XCTAssertEqual(downs.count, 1, "the dip clicks while pinned")
    }

    func testSustainedOffsideReleasesThePin() {
        // Pin, then hold the hand off to one side — inside the hard radius
        // but past the soft line — for a quarter second: reaching, not
        // trembling, so the pin lets go and the cursor follows.
        for i in 0..<30 {
            _ = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                     at: 0.1 + Double(i) / 30)
        }
        var events: [GestureEvent] = []
        for i in 0..<12 {
            events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.518, 0.7))],
                           at: 1.3 + Double(i) / 30).events
        }
        XCTAssertFalse(moves(events).isEmpty, "a sustained offside reach releases the pin")
    }

    func testPinShowsInTheOverlay() {
        var last = OverlayState()
        for i in 0..<30 {
            last = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                        at: 0.1 + Double(i) / 30).overlay
        }
        XCTAssertTrue(last.isPinned, "the overlay paints the pin once acquired")
    }

    func testDisabledNeverPins() {
        var config = GestureConfig.default
        config.hoverAnchoringEnabled = false
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        config.controlTrigger = .anyHand
        engine = GestureEngine(config: config)
        for i in 0..<30 {
            _ = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))],
                     at: 0.1 + Double(i) / 30)
        }
        let events = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.51, 0.7))], at: 1.5)
        XCTAssertFalse(moves(events.events).isEmpty, "off: tracking never pins")
    }
}
