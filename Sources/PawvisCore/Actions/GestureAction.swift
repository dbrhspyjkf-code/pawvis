import Foundation

/// What a bound custom gesture does when it fires. Pure description — the app
/// layer (`GestureActionRunner`) performs it. A flat kind plus one string
/// argument keeps the whole thing trivially Codable and lets the pickers stay
/// dumb; the categories below exist only to group the picker's menu.
public struct GestureAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        // Desktops & Mission Control — Mission Control's own as the stock
        // shortcuts; the desktop switch as a synthesized Dock-swipe, the
        // one thing Spaces answers to (see SpaceSwitcher).
        case desktopLeft, desktopRight, missionControl, appWindows, showDesktop

        // Window management — the focused window, moved and sized directly
        // through the Accessibility API.
        case windowLeftHalf, windowRightHalf, windowTopHalf, windowBottomHalf
        case windowLeftTwoThirds, windowRightTwoThirds
        case windowLeftThird, windowRightThird
        case windowTopLeftQuarter, windowTopRightQuarter
        case windowBottomLeftQuarter, windowBottomRightQuarter
        case windowMaximize, windowCenter, windowMinimize, windowNextDisplay

        // Navigation & media — key chords, plus the hardware media keys:
        // play/pause routes to whatever's playing; volume and brightness act
        // on the system directly and macOS shows its own HUD for both.
        case pressReturn, pressEscape
        case browserBack, browserForward
        case previousTab, nextTab
        case playPause
        case volumeUp, volumeDown, volumeMute
        case brightnessUp, brightnessDown
        /// One step of pinch-zoom at the pointer, the same synthesized
        /// magnify stream the two-palm zoom drives — bindable to any
        /// gesture (a trained pinch, say) as a one-shot step.
        case zoomIn, zoomOut

        // Pawvis itself.
        case stopTracking, toggleVoiceControl

        // Custom — the argument carries the app name, the shell command, or
        // the shortcut to press.
        case openApp, runShellCommand, keyboardShortcut
    }

    public var kind: Kind
    /// App name for `openApp`, command line for `runShellCommand`, chord text
    /// ("cmd+shift+t", "⌘⇧T") for `keyboardShortcut`; empty otherwise.
    public var argument: String

    public init(kind: Kind, argument: String = "") {
        self.kind = kind
        self.argument = argument
    }

    enum CodingKeys: String, CodingKey {
        case kind, argument
    }

    /// `kind` decodes strictly on purpose: a binding saved by a newer Pawvis
    /// with an action this build doesn't know is dropped by the settings
    /// decoder's lossy list rather than misread. Only `argument` is tolerant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        argument = (try? c.decodeIfPresent(String.self, forKey: .argument)) ?? ""
    }

    // MARK: - Picker grouping

    public enum Category: String, CaseIterable, Sendable {
        case desktops, window, navigation, pawvis, custom

        public var displayName: String {
            switch self {
            case .desktops: return String(localized: "Desktops & Mission Control")
            case .window: return String(localized: "Window")
            case .navigation: return String(localized: "Navigate & media")
            case .pawvis: return String(localized: "Pawvis")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    public var category: Category { kind.category }

    // MARK: - Key chords

    /// The chord this action presses, when it is a key action. Mission
    /// Control's own shortcuts and the near-universal app conventions. nil
    /// for everything performed another way — including the desktop switch,
    /// which macOS refuses to perform for synthetic ⌃←/⌃→ (the app
    /// synthesizes the trackpad's Dock-swipe instead; see `SpaceSwitcher`).
    public var keyChord: KeyChord? {
        switch kind {
        case .missionControl: return KeyChord(key: "up", modifiers: [.control])
        case .appWindows: return KeyChord(key: "down", modifiers: [.control])
        case .showDesktop: return KeyChord(key: "f11", modifiers: [])
        case .pressReturn: return KeyChord(key: "return", modifiers: [])
        case .pressEscape: return KeyChord(key: "escape", modifiers: [])
        case .browserBack: return KeyChord(key: "[", modifiers: [.command])
        case .browserForward: return KeyChord(key: "]", modifiers: [.command])
        case .previousTab: return KeyChord(key: "tab", modifiers: [.control, .shift])
        case .nextTab: return KeyChord(key: "tab", modifiers: [.control])
        case .keyboardShortcut: return ShortcutParser.chord(from: argument)
        default: return nil
        }
    }

    // MARK: - Display

    /// Whether this kind is meaningless without its argument filled in.
    public var needsArgument: Bool { kind.needsArgument }

    public var displayName: String { kind.displayName }

    /// The label the picker and the guide show: the kind, plus the argument
    /// when there is one ("Open app: Safari").
    public var summary: String {
        guard kind.needsArgument else { return kind.displayName }
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return kind.displayName }
        return String(format: String(localized: "%1$@: %2$@"), kind.displayName, trimmed)
    }

    /// The short line the status pill flashes when the gesture fires.
    public var feedback: String {
        switch kind {
        case .desktopLeft: return String(localized: "Desktop left")
        case .desktopRight: return String(localized: "Desktop right")
        case .missionControl: return String(localized: "Mission Control")
        case .appWindows: return String(localized: "App windows")
        case .showDesktop: return String(localized: "Show desktop")
        case .windowLeftHalf: return String(localized: "Window → left half")
        case .windowRightHalf: return String(localized: "Window → right half")
        case .windowTopHalf: return String(localized: "Window → top half")
        case .windowBottomHalf: return String(localized: "Window → bottom half")
        case .windowLeftTwoThirds: return String(localized: "Window → left two thirds")
        case .windowRightTwoThirds: return String(localized: "Window → right two thirds")
        case .windowLeftThird: return String(localized: "Window → left third")
        case .windowRightThird: return String(localized: "Window → right third")
        case .windowTopLeftQuarter: return String(localized: "Window → top left")
        case .windowTopRightQuarter: return String(localized: "Window → top right")
        case .windowBottomLeftQuarter: return String(localized: "Window → bottom left")
        case .windowBottomRightQuarter: return String(localized: "Window → bottom right")
        case .windowMaximize: return String(localized: "Window → full screen size")
        case .windowCenter: return String(localized: "Window centered")
        case .windowMinimize: return String(localized: "Window minimized")
        case .windowNextDisplay: return String(localized: "Window → next display")
        case .pressReturn: return String(localized: "Pressed Return")
        case .pressEscape: return String(localized: "Pressed Escape")
        case .browserBack: return String(localized: "Back")
        case .browserForward: return String(localized: "Forward")
        case .previousTab: return String(localized: "Previous tab")
        case .nextTab: return String(localized: "Next tab")
        case .playPause: return String(localized: "Play / pause")
        case .volumeUp: return String(localized: "Volume up")
        case .volumeDown: return String(localized: "Volume down")
        case .volumeMute: return String(localized: "Volume muted")
        case .brightnessUp: return String(localized: "Brightness up")
        case .brightnessDown: return String(localized: "Brightness down")
        case .zoomIn: return String(localized: "Zoomed in")
        case .zoomOut: return String(localized: "Zoomed out")
        case .stopTracking: return String(localized: "Tracking stopped")
        case .toggleVoiceControl: return String(localized: "Voice control toggled")
        case .openApp: return String(format: String(localized: "Opening %@"), argument.trimmingCharacters(in: .whitespaces))
        case .runShellCommand: return String(localized: "Running command")
        case .keyboardShortcut:
            if let chord = keyChord { return String(format: String(localized: "Pressed %@"), ShortcutParser.display(chord)) }
            return String(localized: "Shortcut not understood")
        }
    }
}

extension GestureAction.Kind {
    public var category: GestureAction.Category {
        switch self {
        case .desktopLeft, .desktopRight, .missionControl, .appWindows, .showDesktop:
            return .desktops
        case .windowLeftHalf, .windowRightHalf, .windowTopHalf, .windowBottomHalf,
             .windowLeftTwoThirds, .windowRightTwoThirds, .windowLeftThird, .windowRightThird,
             .windowTopLeftQuarter, .windowTopRightQuarter,
             .windowBottomLeftQuarter, .windowBottomRightQuarter,
             .windowMaximize, .windowCenter, .windowMinimize, .windowNextDisplay:
            return .window
        case .pressReturn, .pressEscape, .browserBack, .browserForward,
             .previousTab, .nextTab, .playPause,
             .volumeUp, .volumeDown, .volumeMute, .brightnessUp, .brightnessDown,
             .zoomIn, .zoomOut:
            return .navigation
        case .stopTracking, .toggleVoiceControl:
            return .pawvis
        case .openApp, .runShellCommand, .keyboardShortcut:
            return .custom
        }
    }

    public var needsArgument: Bool {
        switch self {
        case .openApp, .runShellCommand, .keyboardShortcut: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .desktopLeft: return String(localized: "Desktop to the left")
        case .desktopRight: return String(localized: "Desktop to the right")
        case .missionControl: return String(localized: "Mission Control")
        case .appWindows: return String(localized: "App windows (Exposé)")
        case .showDesktop: return String(localized: "Show desktop")
        case .windowLeftHalf: return String(localized: "Window: left half")
        case .windowRightHalf: return String(localized: "Window: right half")
        case .windowTopHalf: return String(localized: "Window: top half")
        case .windowBottomHalf: return String(localized: "Window: bottom half")
        case .windowLeftTwoThirds: return String(localized: "Window: left two thirds")
        case .windowRightTwoThirds: return String(localized: "Window: right two thirds")
        case .windowLeftThird: return String(localized: "Window: left third")
        case .windowRightThird: return String(localized: "Window: right third")
        case .windowTopLeftQuarter: return String(localized: "Window: top-left quarter")
        case .windowTopRightQuarter: return String(localized: "Window: top-right quarter")
        case .windowBottomLeftQuarter: return String(localized: "Window: bottom-left quarter")
        case .windowBottomRightQuarter: return String(localized: "Window: bottom-right quarter")
        case .windowMaximize: return String(localized: "Window: fill the screen")
        case .windowCenter: return String(localized: "Window: center it")
        case .windowMinimize: return String(localized: "Window: minimize")
        case .windowNextDisplay: return String(localized: "Window: next display")
        case .pressReturn: return String(localized: "Press Return (confirm)")
        case .pressEscape: return String(localized: "Press Escape (dismiss)")
        case .browserBack: return String(localized: "Back (⌘[)")
        case .browserForward: return String(localized: "Forward (⌘])")
        case .previousTab: return String(localized: "Previous tab")
        case .nextTab: return String(localized: "Next tab")
        case .playPause: return String(localized: "Play / pause media")
        case .volumeUp: return String(localized: "Volume up")
        case .volumeDown: return String(localized: "Volume down")
        case .volumeMute: return String(localized: "Mute")
        case .brightnessUp: return String(localized: "Brightness up")
        case .brightnessDown: return String(localized: "Brightness down")
        case .zoomIn: return String(localized: "Zoom in")
        case .zoomOut: return String(localized: "Zoom out")
        case .stopTracking: return String(localized: "Stop hand tracking")
        case .toggleVoiceControl: return String(localized: "Start / stop voice control")
        case .openApp: return String(localized: "Open app")
        case .runShellCommand: return String(localized: "Run shell command")
        case .keyboardShortcut: return String(localized: "Press keyboard shortcut")
        }
    }
}
