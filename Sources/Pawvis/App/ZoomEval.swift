import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import PawvisCore

/// `Pawvis --zoom-eval <total> [steps]` — posts one synthesized pinch-zoom
/// (magnify) gesture stream through the real `MouseController` posting path,
/// at the current pointer, and exits. The ground-truth harness for the zoom
/// synthesis layer: "does a posted magnify stream actually zoom Photos or
/// Preview on THIS machine" is a question for the machine, not for reading
/// the code — Apple documents none of the fields this posts (see
/// `MouseController.postZoom`).
///
/// `total` is the whole magnification (1.0 ≈ zooming in to 2×, −1.0 back),
/// split across `steps` paced events (default 24, ~0.8 s). Negative totals
/// zoom out. Verify against something visible: a photo in Preview or Photos
/// under the pointer, before and after.
///
/// `Pawvis --zoom-eval listen` — installs a session event tap, prints every
/// gesture-type (29) and scroll-type (22) event's interesting fields, and
/// exits on Ctrl-C. Pinch the trackpad over any app while it runs: that is
/// what a REAL magnify stream looks like at the CGEvent level, the reference
/// the synthesized stream must match.
@MainActor
func runZoomEval(_ args: [String]) -> Int32 {
    if args.first == "listen" {
        return listenForZoomEvents()
    }
    if args.first == "camera" {
        return runZoomCameraEval()
    }
    guard let total = args.first.flatMap(Double.init), total != 0 else {
        print("usage: Pawvis --zoom-eval <total> [steps] | listen")
        print("  total  whole magnification (1.0 in, -1.0 out)")
        print("  steps  paced events (default 24)")
        print("  listen  print real gesture/scroll events (pinch the trackpad)")
        print("Run it with the pointer over a photo in Preview or Photos.")
        return 2
    }
    let steps = max(1, args.dropFirst().first.flatMap(Int.init) ?? 24)
    let perStep = total / Double(steps)

    let mouse = MouseController(projector: ScreenProjector(controlAllDisplays: false))
    mouse.zoomGain = 1.0 // the eval takes final magnification verbatim

    // Self-observation: a session tap watching gesture (29) and scroll (22)
    // events, so the eval can prove whether its own posts enter the stream
    // (and with which fields) — a post that never arrives explains "nothing
    // zooms" without touching the engine at all.
    let observer = ZoomEventObserver()

    print("posting zoom: total \(total), \(steps) steps of \(perStep), at the pointer")
    mouse.apply([.zoom(delta: 0, phase: .began)])
    for _ in 1...steps {
        // The engine's deltas are screen-normalized spread; postZoom
        // multiplies zoomGain. Feed it through the same apply path with
        // gain 1 so `perStep` arrives as magnification verbatim.
        mouse.apply([.zoom(delta: perStep, phase: .changed)])
        RunLoop.main.run(until: Date().addingTimeInterval(0.033))
    }
    mouse.apply([.zoom(delta: 0, phase: .ended)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let seen = observer.stop()
    print("tap saw \(seen) gesture/scroll events of our stream "
        + "(\(steps + 2) posted) — did the view under the pointer zoom?")
    return 0
}

/// The fields a magnify stream carries that matter to this comparison:
/// the IOHID subtype (110), the magnification (113), the phase (132), and
/// the scroll-wheel fields a zoom event may arrive wearing.
private let observedFields: [(String, CGEventField)] = [
    ("isCont", .scrollWheelEventIsContinuous),            // 88
    ("scrollCount", CGEventField(rawValue: 90)!),
    ("scrollPhase", CGEventField(rawValue: 91)!),
    ("deltaAxis1", .scrollWheelEventDeltaAxis1),          // 11
    ("pointDelta1", .scrollWheelEventPointDeltaAxis1),    // 96
    ("hidType", CGEventField(rawValue: 110)!),
    ("magnify", CGEventField(rawValue: 113)!),
    ("hidPhase", CGEventField(rawValue: 132)!),
    ("momentum", .scrollWheelEventMomentumPhase),         // 123
]

/// A listen-only session tap that prints gesture (29) and scroll (22)
/// events. Used both to observe the eval's own posts (self-check) and, in
/// `listen` mode, a real trackpad pinch (ground truth).
private final class ZoomEventObserver {
    private var tap: CFMachPort?
    private var count = 0
    private let label: String

    init(label: String = "self") {
        self.label = label
        let gestureType = CGEventType(rawValue: 29)! // NSEventType.gesture, not in CGEventType
        let magnifyType = CGEventType(rawValue: 30)! // NSEventType.magnify, same story
        let mask = (1 << gestureType.rawValue) | (1 << magnifyType.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, info in
                    let observer = Unmanaged<ZoomEventObserver>.fromOpaque(info!).takeUnretainedValue()
                    observer.record(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("tap create failed — no Input Monitoring/Accessibility grant for this host")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func record(type: CGEventType, event: CGEvent) {
        count += 1
        // In listen mode, dump EVERY non-default field: the reference a
        // synthesized stream must match is the real one, field for field.
        let exhaustive = label == "real"
        var parts = ["type=\(type.rawValue)"]
        if exhaustive {
            for raw in 0...250 where raw != 11 && raw != 12 && raw != 13 { // skip huge delta axes noise
                let _ = raw
                let f = CGEventField(rawValue: UInt32(raw))!
                let i = event.getIntegerValueField(f)
                let d = event.getDoubleValueField(f)
                if i != 0 { parts.append("f\(raw)=\(i)") }
                else if d != 0 { parts.append("f\(raw)d=\(String(format: "%.5g", d))") }
            }
        } else {
            for (name, field) in observedFields {
                let i = event.getIntegerValueField(field)
                let d = event.getDoubleValueField(field)
                if i == 0, d == 0 { continue }
                parts.append("\(name)=\(d != 0 ? String(format: "%.4f", d) : String(i))")
            }
        }
        let ns = NSEvent(cgEvent: event)
        if let ns {
            parts.append("nsType=\(ns.type.rawValue)")
            if ns.type == .magnify { parts.append(String(format: "nsMagnify=%.4f", ns.magnification)) }
        }
        print("[\(label)] \(parts.joined(separator: " "))")
    }

    /// Runs the loop briefly so queued tap callbacks fire, then returns how
    /// many events were seen.
    func stop() -> Int {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        return count
    }
}


/// Camera-space palm distance for the diagnostic line: close enough to the
/// engine's screen-space read for tuning against.
private func looseFeaturesPalmDistance(_ hands: [Hand]) -> Double? {
    let palms = hands.compactMap {
        HandFeatures(hand: $0, thresholds: PoseThresholds(), minJointConfidence: 0.25)?
            .pointerPoint(.palmCenter)
    }
    guard palms.count == 2 else { return nil }
    return palms[0].distance(to: palms[1])
}

/// `--zoom-eval listen`: print real gesture/scroll events until Ctrl-C.
private func listenForZoomEvents() -> Int32 {
    print("listening for gesture (29) and scroll (22) events — pinch the trackpad now, Ctrl-C to stop")
    let observer = ZoomEventObserver(label: "real")
    while true {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        _ = observer
    }
    return 0
}

/// `--zoom-eval camera`: the engine-side ground truth. Runs the REAL camera
/// + Vision + gesture-engine pipeline live and prints, per frame, both
/// hands' pinch ratios (permissive and engage-grade confidence), and every
/// zoom state transition and event. Do the two-hand pinch in front of the
/// camera and watch why the engine does (or doesn't) engage.
private func runZoomCameraEval() -> Int32 {
    let session = AVCaptureSession()
    session.sessionPreset = .high
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device) else {
        print("no camera visible from this host — run via:")
        print("  open -n build/Pawvis.app --args --zoom-eval camera")
        return 2
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true

    let tracking = HandTrackingService()
    var config = GestureConfig.default
    config.controlTrigger = .anyHand // watch the pose, not the arming ceremony
    let engine = GestureEngine(config: config)

    final class Box: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var started = false
        var lastPrint = 0.0
        var lastActive: Bool?
        var tracking: HandTrackingService?
        var engine: GestureEngine?

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let tracking, let engine else { return }
            let buffer = sampleBuffer
        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if !started { started = true; print("camera streaming") }
        let hands = tracking.detectHands(in: buffer)
        let (events, overlay) = engine.process(HandFrame(time: t, hands: hands))
        var marks: [String] = []
        for hand in hands {
            // What the engine's pose gate sees: genuinely open, how splayed,
            // and at what joint confidence the open read comes through.
            let loose = HandFeatures(hand: hand, thresholds: PoseThresholds(), minJointConfidence: 0.25)
            let strict = HandFeatures(hand: hand, thresholds: PoseThresholds(), minJointConfidence: 0.40)
            let open = strict?.isOpenHand() == true ? "open" : (loose?.isOpenHand() == true ? "open✗conf" : "closed")
            let splay = loose?.splayAmount().map { String(format: "%.2f", $0) } ?? "–"
            marks.append("\(open) splay=\(splay)")
            // Thumb-signal diagnostics: the pose needs openness ≤ 0.15 (a
            // closed hand), the thumb ≥ 0.85 hand-scales clear of the palm,
            // and 1.5× axis dominance. Print where the hand actually sits.
            if let loose, let palm = loose.palmCenter(), let thumb = loose.hand[.thumbTip] {
                let v = (thumb - palm) / loose.scale
                let closeness = loose.openness().map { String(format: "%.2f", $0) } ?? "–"
                let dir = loose.thumbDirection()?.rawValue ?? "none"
                marks.append(String(
                    format: "fist-open=%@ thumb=(%.2f,%.2f)|%.2f dir=%@",
                    closeness, v.x, v.y, v.length, dir))
            }
        }
        let spread = hands.count == 2
            ? (looseFeaturesPalmDistance(hands) ).map { String(format: " spread=%.2f", $0) } ?? ""
            : ""
        for event in events {
            if case .zoom(let delta, let phase) = event {
                print(String(format: "%7.2fs  ZOOM %@ delta %.4f", t, String(describing: phase), delta))
            }
        }
        if overlay.isZooming != lastActive {
            lastActive = overlay.isZooming
            print(String(format: "%7.2fs  zoom engaged = %@", t, overlay.isZooming ? "YES" : "no"))
        }
        if t - lastPrint > 0.25 {
            lastPrint = t
            print(String(format: "%7.2fs  hands=%d  %@", t, hands.count,
                         marks.joined(separator: " | ") + spread))
        }
        }
    }
    let box = Box()
    box.tracking = tracking
    box.engine = engine
    let queue = DispatchQueue(label: "zoom-eval.cam")
    output.setSampleBufferDelegate(box, queue: queue)
    session.addOutput(output)
    session.startRunning()
    print("watching for 45 s — do the two-hand pinch (both hands, thumb+index tips together) and spread them")
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    session.stopRunning()
    return 0
}
