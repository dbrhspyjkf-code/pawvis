import AppKit
import CoreGraphics
import Foundation
import PawvisCore

/// Moves to the neighboring virtual desktop.
///
/// Not by pressing ⌃← / ⌃→: on current macOS the Spaces-switching hotkeys
/// ignore synthetic keyboard events outright — measured with every variant
/// (flags-only, real modifier key events, fn/numpad flags, System Events),
/// while other symbolic hotkeys (Spotlight, Mission Control, show desktop)
/// respond fine.
///
/// And not by SkyLight's `SLSManagedDisplaySetCurrentSpace`, which this
/// class shipped first. Called from outside Dock.app, that function updates
/// the window server's *bookkeeping* — `SLSGetActiveSpace` dutifully
/// reports the new space — while the screen never moves: the visible
/// switch also needs state private to Dock, which is why yabai injects
/// code into Dock to make this very call. Our "every switch is verified
/// against SLSGetActiveSpace" check was an echo chamber — it read back our
/// own phantom write and the pill said "Desktop right" over a screen that
/// hadn't budged.
///
/// What does switch, from a normal process with SIP fully on, is the
/// WindowServer's own gesture pipeline: a synthesized Dock-swipe CGEvent,
/// the private event a trackpad's multi-finger space swipe becomes after
/// interpretation. One Began/Ended pair moves exactly one space in the
/// Mission Control ring. Same technique BetterTouchTool ships and yabai
/// falls back to when its scripting addition isn't loaded; measured here:
/// the screen actually moves. The swipe lands on the display under the
/// pointer (the WindowServer's routing rule for space gestures), so ring,
/// step count, and verification are all computed for that display.
/// SkyLight stays for *reads only* — `SLSCopyManagedDisplaySpaces` for
/// each display's ring and current space — resolved at runtime with dlsym;
/// if a future macOS removes the symbols, the action reports that honestly
/// ("Desktop switching isn't available on this macOS"). Nothing else in
/// Pawvis depends on it.
@MainActor
final class SpaceSwitcher {
    enum Direction {
        case left, right
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private struct SkyLight {
        let connection: Int32
        let copySpaces: CopySpacesFn
    }

    /// Resolved once; nil when the private symbols are gone.
    private lazy var skyLight: SkyLight? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let main = symbol("SLSMainConnectionID", as: MainConnectionFn.self),
              let copy = symbol("SLSCopyManagedDisplaySpaces", as: CopySpacesFn.self) else {
            return nil
        }
        return SkyLight(connection: main(), copySpaces: copy)
    }()

    private var busy = false

    /// One space in a display's ring: its window-server id and whether it
    /// is a user desktop (`type == 0`) rather than a full-screen app's
    /// space (`type == 4`).
    struct Space: Equatable {
        let id: UInt64
        let isDesktop: Bool
    }

    /// One managed display: its identifier (a display UUID string when
    /// "Displays have separate Spaces" is on; the literal "Main" for the
    /// single spanning arrangement when it is off), the space it currently
    /// shows, and its ring.
    struct DisplayRing: Equatable {
        let identifier: String
        let current: UInt64
        let spaces: [Space]
    }

    /// The display the swipe will land on: the one under the pointer.
    /// Matching is by display UUID; the single-display (or spanning
    /// "Main") arrangement has nothing to choose. nil means the layout and
    /// the pointer position couldn't be reconciled — better to refuse than
    /// to switch a display the ring math wasn't about.
    nonisolated static func pointerDisplay(in displays: [DisplayRing],
                                           pointerUUID: String?) -> DisplayRing? {
        if displays.count == 1 { return displays.first }
        guard let pointerUUID else { return nil }
        return displays.first(where: { $0.identifier == pointerUUID })
    }

    /// The neighboring *desktop* in the given direction, skipping the
    /// full-screen app spaces that share the ring: the action is named
    /// "desktop", and landing on someone's full-screen window reads as
    /// window shuffling, not desktop switching. Works from a full-screen
    /// space too (you flung mid-movie): the scan just continues to the
    /// nearest desktop on that side. nil when there is none.
    nonisolated static func neighborDesktop(in spaces: [Space], active: UInt64,
                                            direction: Direction) -> UInt64? {
        guard let current = spaces.firstIndex(where: { $0.id == active }) else { return nil }
        let step = direction == .left ? -1 : 1
        var target = current + step
        while target >= 0 && target < spaces.count {
            if spaces[target].isDesktop { return spaces[target].id }
            target += step
        }
        return nil
    }

    /// How many swipe steps reach `target`: the swipe walks every ring
    /// entry, full-screen spaces included, so a skipped full-screen space
    /// costs an extra step. nil when either id is missing from the ring.
    nonisolated static func swipeSteps(in spaces: [Space], from active: UInt64,
                                       to target: UInt64) -> Int? {
        guard let a = spaces.firstIndex(where: { $0.id == active }),
              let b = spaces.firstIndex(where: { $0.id == target }) else { return nil }
        return abs(b - a)
    }

    /// Every managed display's ring and current space, or nil when the
    /// layout can't be read.
    private func readDisplays(_ sky: SkyLight) -> [DisplayRing]? {
        guard let dicts = sky.copySpaces(sky.connection)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        let displays = dicts.compactMap { display -> DisplayRing? in
            guard let identifier = display["Display Identifier"] as? String,
                  let current = ((display["Current Space"] as? [String: Any])?["id64"]
                                 as? NSNumber)?.uint64Value,
                  let spaceDicts = display["Spaces"] as? [[String: Any]] else { return nil }
            let spaces = spaceDicts.compactMap { dict -> Space? in
                guard let id = (dict["id64"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, isDesktop: ((dict["type"] as? NSNumber)?.intValue ?? 0) == 0)
            }
            return DisplayRing(identifier: identifier, current: current, spaces: spaces)
        }
        return displays.isEmpty ? nil : displays
    }

    /// The UUID string of the display under the pointer, for matching
    /// against managed-display identifiers. nil off-screen or on failure.
    private func pointerDisplayUUID() -> String? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The WindowServer's space-switch pipeline, entered where the trackpad
    /// swipe enters it. macOS 27 stopped reading the plain CGEventFields the
    /// previous layout set (measured here: the swipe posts, nothing moves),
    /// so this posts the field-for-field layout Mac Mouse Fix's Tahoe branch
    /// ships: a type-30 carrier with the DockSwipe payload (subtype 110=23,
    /// phases in 132/134, the running origin offset in 124 and its
    /// float32-bits encoding in 135, the direction selector in 119/139 and
    /// 123/165, exit speed in 129/130 when ending), a bare type-29 companion
    /// after each carrier, and the end pair re-posted once at +0.2 s — the
    /// "stuck bug" guard, a WindowServer under load drops the first end.
    /// The switch route that still works on this macOS: through Mission
    /// Control's own keyboard focus. The Dock-swipe synthesis this class
    /// shipped — both the old plain-field layout and the field-for-field
    /// Tahoe layout transcribed from a real captured swipe, HID source
    /// state included — posts cleanly and moves nothing on macOS 27
    /// (measured against a tap capture of a real swipe; the carrier is
    /// accepted but the gesture pipeline drops what it can't attribute to
    /// real hardware). Mission Control, by contrast, answers the
    /// synthesized fn+⌃↑ that already drives the missionControl action,
    /// and once it holds the screen its keyboard focus takes plain arrow
    /// keys and Return. Measured live: space 31 → 53 through fn+⌃↑, ←,
    /// Return, verified against the SkyLight read.
    ///
    /// The cost is visible: Mission Control flashes on screen for ~0.7 s
    /// on the way to the target desktop. Slower than a swipe, and the
    /// only door macOS 27 left open.
    private func postViaMissionControl(direction: Direction, steps: Int) async {
        await Task.detached(priority: .userInitiated) {
            let src = CGEventSource(stateID: .hidSystemState)
            func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
                guard let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
                      let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
                else { return }
                d.flags = flags
                d.post(tap: .cghidEventTap)
                usleep(20_000)
                u.flags = flags
                u.post(tap: .cghidEventTap)
            }
            key(126, [.maskSecondaryFn, .maskControl]) // Mission Control opens
            usleep(700_000) // let it take the screen and the keyboard focus
            let arrow: CGKeyCode = direction == .left ? 123 : 124
            for _ in 0..<steps {
                key(arrow)
                usleep(300_000)
            }
            key(36) // Return commits the focused space
        }.value
    }

    /// A dismissal for the failure path: if the commit never landed,
    /// Mission Control may still be holding the screen — leave nothing
    /// open behind a failed switch.
    private func dismissMissionControl() async {
        await Task.detached(priority: .userInitiated) {
            let src = CGEventSource(stateID: .hidSystemState)
            guard let d = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
                  let u = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)
            else { return }
            d.post(tap: .cghidEventTap)
            usleep(20_000)
            u.post(tap: .cghidEventTap)
        }.value
    }

    /// Perform the switch; the returned line is the status-pill outcome.
    func switchDesktop(_ direction: Direction) async -> String {
        guard !busy else { return "Still switching…" }
        busy = true
        defer { busy = false }

        guard let sky = skyLight else {
            return "Desktop switching isn't available on this macOS"
        }
        guard let displays = readDisplays(sky) else {
            return "Couldn't read the desktop layout"
        }
        guard let display = Self.pointerDisplay(in: displays,
                                                pointerUUID: pointerDisplayUUID()) else {
            return "Couldn't find the active desktop"
        }

        guard let target = Self.neighborDesktop(in: display.spaces, active: display.current,
                                                direction: direction) else {
            return direction == .left ? "No desktop to the left" : "No desktop to the right"
        }
        let steps = Self.swipeSteps(in: display.spaces, from: display.current, to: target) ?? 1

        await postViaMissionControl(direction: direction, steps: steps)

        // Verified, not assumed — and meaningful: nothing here writes the
        // window server's state, so a changed current space can only be the
        // system actually having switched. The window is generous because
        // the route itself takes ~1.5 s of animations.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let now = readDisplays(sky),
               now.first(where: { $0.identifier == display.identifier })?.current == target {
                return direction == .left ? "Desktop left" : "Desktop right"
            }
        }
        await dismissMissionControl()
        return "Desktop didn't switch"
    }
}
