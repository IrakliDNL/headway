import Foundation

/// Everything the user can change.
public struct HeadwaySettings: Codable, Equatable, Sendable {
    /// Switching screens: glances shorter than this are ignored (seconds).
    public var switchDelay: Double = 0.30
    /// Switching screens: how far towards another screen to turn before it takes over (0…1).
    public var headTurn: Double = 0.50
    /// Same screen: focus the window or pane being looked at.
    public var focusWithinScreen = true
    /// Same screen: how long to look before a window or pane gets focus (seconds).
    public var paneDelay: Double = 0.30
    /// While typing: panes of the same app stay put; other windows and screens take over only after a
    /// longer look (`typingScreenDelay`).
    public var waitWhileTyping = true
    /// While typing: how long after the last keystroke to keep waiting (seconds).
    public var typingPause: Double = 3.0
    /// Move the pointer along to the screen being turned to.
    public var movePointer = true
    /// Terminals and editors that can't have a pane focused directly get a click in the pane's middle.
    public var clickToFocusPanes = true
    /// Each click teaches the model where that head pose was looking.
    public var learnFromClicks = true
    /// Draw a dot where Headway thinks you're looking (for testing).
    public var showGazeDot = false
    /// Camera unique ID; nil = built-in.
    public var cameraID: String?
    /// Analyse half the camera's frames, and a third once head and eyes are still.
    public var batterySaver = true
    /// Camera off after 5 minutes with no keyboard or mouse; back on at the next touch.
    public var idlePause = true

    /// While the mouse or trackpad is in use, and this long after, nothing moves (seconds).
    public static let mouseQuiet = 1.5
    /// While typing, looking at another screen or window still switches — after this long (seconds).
    public static let typingScreenDelay = 1.0
    /// Extra turn needed beyond the threshold, so looking at a bezel doesn't ping-pong.
    public static let edgeHysteresis = 0.06

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate settings saved by older builds: anything missing keeps its default.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeadwaySettings()
        switchDelay = try c.decodeIfPresent(Double.self, forKey: .switchDelay) ?? d.switchDelay
        headTurn = try c.decodeIfPresent(Double.self, forKey: .headTurn) ?? d.headTurn
        focusWithinScreen = try c.decodeIfPresent(Bool.self, forKey: .focusWithinScreen) ?? d.focusWithinScreen
        paneDelay = try c.decodeIfPresent(Double.self, forKey: .paneDelay) ?? d.paneDelay
        waitWhileTyping = try c.decodeIfPresent(Bool.self, forKey: .waitWhileTyping) ?? d.waitWhileTyping
        typingPause = try c.decodeIfPresent(Double.self, forKey: .typingPause) ?? d.typingPause
        movePointer = try c.decodeIfPresent(Bool.self, forKey: .movePointer) ?? d.movePointer
        clickToFocusPanes = try c.decodeIfPresent(Bool.self, forKey: .clickToFocusPanes) ?? d.clickToFocusPanes
        learnFromClicks = try c.decodeIfPresent(Bool.self, forKey: .learnFromClicks) ?? d.learnFromClicks
        showGazeDot = try c.decodeIfPresent(Bool.self, forKey: .showGazeDot) ?? d.showGazeDot
        cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID)
        batterySaver = try c.decodeIfPresent(Bool.self, forKey: .batterySaver) ?? d.batterySaver
        idlePause = try c.decodeIfPresent(Bool.self, forKey: .idlePause) ?? d.idlePause
    }
}
