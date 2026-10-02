import XCTest
@testable import PawvisCore

/// The two-hand spread zoom: both hands open and relaxed, the distance
/// between the palms drives a synthesized trackpad magnify gesture. The
/// same suite shape as the scroll's: engage, release, the hysteresis band,
/// tracking loss, and the guards (an open palm reads as no dip, so a
/// forming zoom never blocks a click; a press or scroll always wins).
final class GestureEngineZoomTests: XCTestCase {
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

    @discardableResult
    private func feedFrames(_ hands: [Hand], from: TimeInterval, count: Int) -> [GestureEvent] {
        var events: [GestureEvent] = []
        for i in 0..<count {
            events += feed(hands, at: from + Double(i) / 30).events
        }
        return events
    }

    /// The default zoom pose: two relaxed open hands, comfortably apart.
    /// The palm center rides a fixed offset from each wrist, so moving the
    /// wrists apart widens the spread one for one.
    private func openPair(leftWrist: Vec2 = Vec2(0.30, 0.70),
                          rightWrist: Vec2 = Vec2(0.70, 0.70)) -> [Hand] {
        [SyntheticHand.openRelaxed(wrist: leftWrist),
         SyntheticHand.openRelaxed(wrist: rightWrist)]
    }

    private func zooms(_ events: [GestureEvent]) -> [(delta: Double, phase: ZoomPhase)] {
        events.compactMap {
            if case .zoom(let delta, let phase) = $0 { return (delta, phase) }
            return nil
        }
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    private func downs(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .buttonDown(.left, let at, _) = $0 { return at }
            return nil
        }
    }

    private func scrolls(_ events: [GestureEvent]) -> [Double] {
        events.compactMap {
            if case .scroll(_, let deltaY) = $0 { return deltaY }
            return nil
        }
    }

    /// Engages the zoom and returns the events of the engaging frames. The
    /// debounce is the shared `pinchDebounceFrames` (2): the second
    /// consecutive two-open-palms frame begins the stream.
    private func engage(from: TimeInterval = 0.1) -> [GestureEvent] {
        feedFrames(openPair(), from: from, count: 3)
    }

    // MARK: Engage and travel

    func testTwoOpenPalmsBeginTheZoomStream() {
        let events = zooms(engage())
        XCTAssertEqual(events.first?.phase, .began, "the stream opens with a began")
        XCTAssertEqual(events.first?.delta ?? -1, 0, "the began carries no travel")
        XCTAssertEqual(events.filter { $0.phase == .began }.count, 1)
    }

    func testSpreadApartZoomsInAndTogetherZoomsOut() {
        engage()
        // Apart: each hand travels 0.1 outward, so the spread grows 0.2 over
        // four frames of 0.05 each.
        var events: [GestureEvent] = []
        for i in 1...4 {
            events += feed(openPair(leftWrist: Vec2(0.30 - 0.1 * Double(i) / 4, 0.70),
                                    rightWrist: Vec2(0.70 + 0.1 * Double(i) / 4, 0.70)),
                           at: 0.3 + Double(i) / 30).events
        }
        let changed = zooms(events).filter { $0.phase == .changed }
        XCTAssertFalse(changed.isEmpty, "spreading emits changed deltas")
        XCTAssertTrue(changed.allSatisfy { $0.delta > 0 }, "apart = zoom in = positive")
        XCTAssertEqual(changed.reduce(0.0) { $0 + $1.delta }, 0.2, accuracy: 0.01,
                       "deltas sum to the whole travel")

        // And back together: negative deltas, same anchor discipline.
        var closing: [GestureEvent] = []
        for i in 1...4 {
            closing += feed(openPair(leftWrist: Vec2(0.20 + 0.1 * Double(i) / 4, 0.70),
                                     rightWrist: Vec2(0.80 - 0.1 * Double(i) / 4, 0.70)),
                            at: 0.5 + Double(i) / 30).events
        }
        let closingDeltas = zooms(closing).filter { $0.phase == .changed }
        XCTAssertTrue(closingDeltas.allSatisfy { $0.delta < 0 }, "together = zoom out = negative")
    }

    func testDeadbandSwallowsShimmer() {
        engage()
        // A spread jitter of half the deadband emits nothing.
        let events = feed(openPair(leftWrist: Vec2(0.302, 0.70),
                                   rightWrist: Vec2(0.702, 0.70)),
                          at: 0.25).events
        XCTAssertTrue(zooms(events).isEmpty, "shimmer is not zoom")
    }

    // MARK: Release and the guards

    func testClosingAHandEndsTheStream() {
        engage()
        // One hand closes into a fist: the hold (2+ curled fingers breaks
        // it) releases after the debounce.
        var events: [GestureEvent] = []
        events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.30, 0.70)),
                        SyntheticHand.fist(wrist: Vec2(0.70, 0.70))],
                       at: 0.25).events
        XCTAssertTrue(zooms(events).filter { $0.phase == .ended }.isEmpty,
                      "one frame holds — the release is debounced")
        events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.30, 0.70)),
                        SyntheticHand.fist(wrist: Vec2(0.70, 0.70))],
                       at: 0.2833).events
        XCTAssertEqual(zooms(events).filter { $0.phase == .ended }.count, 1,
                       "the debounce releases exactly one ended")
    }

    func testSplayedHandsDoNotEngage() {
        // Splayed fingers belong to the criss-cross wave; the zoom demands
        // relaxed-together fingers, so the two can never court the same
        // frame.
        let events = feedFrames([SyntheticHand.openSplayed(wrist: Vec2(0.30, 0.70)),
                                  SyntheticHand.openSplayed(wrist: Vec2(0.70, 0.70))],
                                 from: 0.1, count: 4)
        XCTAssertTrue(zooms(events).isEmpty, "splayed is the wave's pose, not the zoom's")
    }

    func testFistsDoNotEngage() {
        let events = feedFrames([SyntheticHand.fist(wrist: Vec2(0.30, 0.70)),
                                  SyntheticHand.fist(wrist: Vec2(0.70, 0.70))],
                                 from: 0.1, count: 4)
        XCTAssertTrue(zooms(events).isEmpty)
    }

    func testNearbyHandsDoNotEngage() {
        // Two open hands resting close together is typing-adjacent, not a
        // caliper: the engage demands real separation.
        let events = feedFrames(openPair(leftWrist: Vec2(0.46, 0.70),
                                         rightWrist: Vec2(0.54, 0.70)),
                                from: 0.1, count: 4)
        XCTAssertTrue(zooms(events).isEmpty)
    }

    func testOneHandIsNotThePose() {
        let events = feedFrames([SyntheticHand.openRelaxed()],
                                from: 0.1, count: 4)
        XCTAssertTrue(zooms(events).isEmpty, "the zoom needs both hands")
    }

    func testSecondOpenHandDoesNotBlockClicks() {
        // The forming zoom must not veto a genuine click: open palms read
        // as no dip, so with both hands open the primary's index tap still
        // clicks (the press then keeps the zoom out, same frame).
        let events = feedFrames([SyntheticHand.mouseTap(indexDown: true),
                                 SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.7))],
                                from: 0.1, count: 3)
        XCTAssertFalse(downs(events).isEmpty,
                       "a click lands even with a second open hand in frame")
    }

    func testPressWinsTheZoomCannotEngage() {
        // A held press blocks zoom engagement, exactly as it blocks scroll.
        // The dip hand stays dipped (the press holds) while the second hand
        // is open — the pose never forms around a held button.
        let events = feedFrames([SyntheticHand.mouseTap(indexDown: true),
                                 SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.7))],
                                from: 0.1, count: 7)
        XCTAssertFalse(downs(events).isEmpty, "sanity: the press exists")
        XCTAssertTrue(zooms(events).isEmpty,
                      "a held press keeps the zoom out for as long as it holds")
    }

    func testScrollAndZoomExcludeEachOther() {
        // Scroll first: the primary hand holds the scroll pose and travels
        // (a stationary scroll engages but emits nothing), and the zoom may
        // not start under it — even though the other hand is open.
        var events: [GestureEvent] = []
        for i in 0..<5 {
            events += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02)),
                            SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.7))],
                           at: 0.1 + Double(i) / 30).events
        }
        XCTAssertFalse(scrolls(events).isEmpty, "the scroll pose scrolls")
        XCTAssertTrue(zooms(events).filter { $0.phase == .began }.isEmpty,
                      "an active scroll keeps the zoom out")

        // Zoom first: while it holds, scroll cannot engage. The scroll pose
        // (two fingers folded) stays inside the zoom's loose hold, so the
        // zoom survives it — the exclusion is the guard's, not a release.
        setUp() // fresh engine
        engage(from: 2.0)
        var under: [GestureEvent] = []
        for i in 0..<3 {
            under += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02)),
                           SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.7))],
                          at: 2.2 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolls(under).isEmpty,
                      "while the zoom holds, the scroll cannot engage")
        XCTAssertTrue(zooms(under).filter { $0.phase == .ended }.isEmpty,
                      "a scroll pose on one hand is not a zoom release")
    }

    func testCursorParksWhileZooming() {
        engage()
        // Both hands travel vertically together: the spread holds, the
        // cursor would move — but must not.
        var events: [GestureEvent] = []
        for i in 1...4 {
            let y = 0.70 - 0.05 * Double(i)
            events += feed(openPair(leftWrist: Vec2(0.30, y),
                                    rightWrist: Vec2(0.70, y)),
                           at: 0.3 + Double(i) / 30).events
        }
        XCTAssertTrue(moves(events).isEmpty, "the cursor parks while the zoom holds")
    }

    func testOverlayMarksTheZoom() {
        let (_, first) = feed(openPair(), at: 0.1)
        XCTAssertFalse(first.isZooming, "not before the debounce")
        let (_, held) = feed(openPair(), at: 0.1333)
        XCTAssertTrue(held.isZooming, "the ring paints while the zoom holds")
    }

    // MARK: Tracking loss and unwind

    func testDroppedPartnerGetsTheGrace() {
        engage()
        // One hand vanishes mid-zoom: inside the grace the stream holds
        // (Vision drops a hand exactly when the two overlap).
        var events: [GestureEvent] = []
        events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))],
                       at: 0.25).events
        events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))],
                       at: 0.3833).events // 0.1333 s later: still inside 0.3 s
        XCTAssertTrue(zooms(events).filter { $0.phase == .ended }.isEmpty,
                      "a one-hand dropout inside the grace holds the zoom")
        // Past the grace, the stream ends.
        events += feed([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))],
                       at: 0.65).events // 0.4 s after the last pair: past it
        XCTAssertEqual(zooms(events).filter { $0.phase == .ended }.count, 1)
    }

    func testForceReleaseEndsTheZoom() {
        engage()
        let events = engine.forceRelease(at: 0.5)
        XCTAssertEqual(zooms(events).filter { $0.phase == .ended }.count, 1,
                       "the release path (stop, lock, attention) ends the stream")
    }

    func testDisablingMidFlightEndsTheZoom() {
        engage()
        var config = engine.config
        config.zoomEnabled = false
        engine.config = config
        let events = feed(openPair(), at: 0.25).events
        XCTAssertEqual(zooms(events).filter { $0.phase == .ended }.count, 1,
                       "the switch off flushes an ended on the next frame")
        XCTAssertTrue(zooms(feedFrames(openPair(), from: 0.3, count: 3)).isEmpty,
                      "and the pose no longer engages at all")
    }

    func testZoomDisabledNeverEngages() {
        var config = engine.config
        config.zoomEnabled = false
        engine.config = config
        let events = feedFrames(openPair(), from: 0.1, count: 4)
        XCTAssertTrue(zooms(events).isEmpty)
    }

    // MARK: Snap home

    func testClosingAllTheWaySnapsHome() {
        engage()
        // Zoom in a bit first: 0.1 of spread each way, net +0.2.
        for i in 1...4 {
            _ = feed(openPair(leftWrist: Vec2(0.30 - 0.1 * Double(i) / 4, 0.70),
                              rightWrist: Vec2(0.70 + 0.1 * Double(i) / 4, 0.70)),
                     at: 0.3 + Double(i) / 30).events
        }
        // Close all the way — palms inside the reset spread — and hold long
        // enough for the payback sequence to run to its end.
        var events: [GestureEvent] = []
        for i in 0..<70 {
            let t = min(Double(i) / 8, 1) // close over ~8 frames, then hold
            let lx = 0.20 + t * 0.27      // 0.20 -> 0.47
            let rx = 0.80 - t * 0.27      // 0.80 -> 0.53
            events += feed(openPair(leftWrist: Vec2(lx, 0.70),
                                    rightWrist: Vec2(rx, 0.70)),
                           at: 0.5 + Double(i) / 30).events
        }
        let changed = zooms(events).filter { $0.phase == .changed }
        let negative = changed.filter { $0.delta < 0 }
        XCTAssertFalse(negative.isEmpty, "closing all the way starts the payback")
        let payback = -negative.reduce(0.0) { $0 + $1.delta }
        // The payback owes the session's net zoom-in (0.2) plus the margin
        // (2.5) — enough to drive any pinch-aware app to its fit floor —
        // and the closing travel itself (another ~0.54 of ordinary
        // negative deltas along the way). Holding the pose closed does NOT
        // re-trigger the sequence (the homed latch).
        // The closing travel (~0.5; the frame that crosses into the reset
        // band belongs to the latch, not the ledger) plus the payback
        // (2.5). Exactly once — the homed latch holds while the pose stays
        // closed.
        XCTAssertEqual(payback, 0.47 + 2.5, accuracy: 0.12,
                       "hands together = back to the original size, once")
    }

    func testOpeningAbortsTheSnapHome() {
        engage()
        // Close all the way to start the payback, then open again mid-sequence.
        var events: [GestureEvent] = []
        for i in 0..<8 {
            events += feed(openPair(leftWrist: Vec2(0.46, 0.70),
                                    rightWrist: Vec2(0.54, 0.70)),
                           at: 0.4 + Double(i) / 30).events
        }
        let paybackStarted = zooms(events)
            .filter { $0.phase == .changed && $0.delta < 0 }
            .reduce(0.0) { $0 - $1.delta }
        XCTAssertGreaterThan(paybackStarted, 0.3, "sanity: the payback is running")
        // Open back past the reset band: the sequence stops, ordinary
        // incremental zooming resumes from the new spread.
        events = []
        for i in 1...4 {
            events += feed(openPair(leftWrist: Vec2(0.30 - 0.1 * Double(i) / 4, 0.70),
                                    rightWrist: Vec2(0.70 + 0.1 * Double(i) / 4, 0.70)),
                           at: 0.8 + Double(i) / 30).events
        }
        let changed = zooms(events).filter { $0.phase == .changed }
        XCTAssertFalse(changed.isEmpty, "zooming resumes after the abort")
        XCTAssertTrue(changed.allSatisfy { $0.delta > -0.2 },
                      "no more payback-sized steps once the hands open")
    }
}
