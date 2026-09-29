import AppKit
import AVFoundation
import Combine
import HeadwayCore

enum TrackingStatus: Equatable {
    case needsCamera
    case needsAccessibility
    case needsCalibration
    case paused
    case asleep
    case calibrating
    case cameraProblem(String)
    case noFace
    case lookingAway
    case facing(String)
    case starting

    var title: String {
        switch self {
        case .needsCamera: return "Needs camera access"
        case .needsAccessibility: return "Needs Accessibility permission"
        case .needsCalibration: return "Needs calibration"
        case .paused: return "Paused"
        case .asleep: return "Resting while the Mac is locked"
        case .calibrating: return "Calibrating…"
        case .cameraProblem(let why): return "Camera problem: \(why)"
        case .noFace: return "Can't see your face"
        case .lookingAway: return "Looking away from the screens"
        case .facing(let name): return "Facing \(name)"
        case .starting: return "Starting…"
        }
    }

    var isWorking: Bool {
        switch self {
        case .facing, .noFace, .lookingAway, .starting: return true
        default: return false
        }
    }
}

/// Connects everything: camera → face numbers → model → engine → focus. Lives on the main thread.
@MainActor
final class Coordinator: ObservableObject {
    // What the UI shows. Published at most a few times a second.
    @Published private(set) var status: TrackingStatus = .starting
    @Published private(set) var faceVisible = false
    @Published private(set) var settings: HeadwaySettings
    @Published private(set) var paused: Bool
    @Published private(set) var calibratedKeys: Set<String> = []
    @Published private(set) var screens: [ScreenGeometry] = []
    @Published private(set) var suggestRecalibration = false
    @Published private(set) var learnedClicks = 0
    @Published private(set) var axTrusted = AX.isTrusted
    @Published private(set) var cameraAuthorized = CameraService.authorization == .authorized

    private(set) var store: CalibrationStore
    private(set) var model: GazeModel?
    private(set) var lastReading: GazeReading?
    private(set) var lastSample: FaceSample?

    let camera = CameraService()
    let engine: FocusEngine
    let tracker = FocusTracker()
    let focuser = FocusController()
    let panes = PaneFinder()
    lazy var targets = TargetProvider(panes: panes)
    let overlay = GazeOverlay()
    let system = SystemWatcher()
    private var smoother = SampleSmoother()
    private var accuracy = AccuracyTracker()

    /// While set, raw samples go here instead of the engine (calibration is running).
    var calibrationSink: ((FaceSample?) -> Void)?
    /// Keeps the camera on for the welcome window's face check.
    var previewRequested = false { didSet { reconsiderCamera() } }

    private var clickMonitor: Any?
    private var clicksSinceRefit = 0
    private var ignoreClicksUntil = 0.0
    private var lastUIUpdate = 0.0
    private var lastDebugWrite = 0.0
    private var cameraError: String?
    private var housekeeping: Timer?
    private var saveWork: DispatchWorkItem?

    init() {
        let saved = Storage.loadSettings()
        settings = saved
        store = Storage.loadStore()
        paused = UserDefaults.standard.bool(forKey: "paused")
        engine = FocusEngine(settings: saved)
    }

    // MARK: Lifecycle

    func boot() {
        // One busy app (Xcode indexing, say) must never stall Headway for the default six seconds.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        panes.clickFallback = settings.clickToFocusPanes
        panes.enabled = settings.focusWithinScreen
        panes.onSyntheticClick = { [weak self] in self?.ignoreClicksUntil = CACurrentMediaTime() + 0.5 }
        refreshScreens()
        camera.onSample = { [weak self] sample in
            DispatchQueue.main.async { self?.frame(sample) }
        }
        system.onChange = { [weak self] in
            guard let self else { return }
            Log.event(self.system.asleep ? "system: locked/asleep — camera off" : "system: awake")
            self.engine.reset()
            self.reconsiderCamera()
            self.updateStatus(force: true)
        }
        system.onScreensChanged = { [weak self] in
            Log.event("screens changed")
            self?.refreshScreens()
        }
        system.start()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClick() }
        }
        // Permissions can be granted in System Settings at any time; notice without a restart.
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeep() }
        }
        reconsiderCamera()
        updateStatus(force: true)
        Log.event("boot: screens=\(screens.map(\.name)) calibrated=\(calibratedKeys.count) paused=\(paused)")
    }

    private func housekeep() {
        let ax = AX.isTrusted
        let cam = CameraService.authorization == .authorized
        if ax != axTrusted || cam != cameraAuthorized {
            axTrusted = ax
            cameraAuthorized = cam
            reconsiderCamera()
        }
        updateStatus(force: true)
    }

    func refreshScreens() {
        screens = Displays.current().map(\.geometry)
        targets.invalidate()
        rebuildModel()
        overlay.rebuild()
    }

    func rebuildModel() {
        model = GazeModel(samples: store.allSamples, screens: screens)
        calibratedKeys = Set(store.samples.map(\.screen)).intersection(screens.map(\.key))
        learnedClicks = store.clicks.count
        engine.reset()
        suggestRecalibration = !store.movedScreens(current: screens).isEmpty || accuracy.suggestsRecalibration
        reconsiderCamera()
        updateStatus(force: true)
    }

    var uncalibratedScreens: [ScreenGeometry] {
        screens.filter { !calibratedKeys.contains($0.key) }
    }

    /// The camera runs only while it has a job: tracking, calibrating, or the welcome window's face check.
    func reconsiderCamera() {
        let wanted = cameraAuthorized && !system.asleep
            && (calibrationSink != nil || previewRequested || (!paused && model != nil && axTrusted))
        if wanted && !camera.isRunning {
            do {
                try camera.start(deviceID: settings.cameraID)
                cameraError = nil
                smoother.reset()
                Log.event("camera on: \(camera.deviceName ?? "?")")
            } catch {
                cameraError = "\(error)"
                Log.event("camera failed: \(error)")
            }
        } else if !wanted && camera.isRunning {
            camera.stop()
            faceVisible = false
            overlay.hide()
            Log.event("camera off")
        }
    }

    func restartCamera() {
        camera.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reconsiderCamera() }
    }

    // MARK: Controls

    func setPaused(_ p: Bool) {
        paused = p
        UserDefaults.standard.set(p, forKey: "paused")
        engine.reset()
        reconsiderCamera()
        if p { overlay.hide() }
        updateStatus(force: true)
        Log.event(p ? "paused" : "resumed")
    }

    func togglePause() { setPaused(!paused) }

    func update(_ change: (inout HeadwaySettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let cameraChanged = s.cameraID != settings.cameraID
        settings = s
        engine.settings = s
        panes.clickFallback = s.clickToFocusPanes
        panes.enabled = s.focusWithinScreen
        Storage.save(s)
        if !s.showGazeDot { overlay.hide() }
        if cameraChanged { restartCamera() }
    }

    func forgetClicks() {
        store.forgetClicks()
        accuracy.reset()
        saveStore()
        rebuildModel()
    }

    func applyCalibration(_ results: [(ScreenGeometry, [TrainingSample])]) {
        for (screen, samples) in results { store.replaceCalibration(screen, with: samples) }
        accuracy.reset()
        saveStore()
        rebuildModel()
        Log.event("calibrated \(results.map { "\($0.0.name)=\($0.1.count)" }.joined(separator: " "))")
    }

    private func saveStore() {
        saveWork?.cancel()
        let snapshot = store
        let work = DispatchWorkItem { Storage.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: The loop

    private func frame(_ raw: FaceSample?) {
        if let sink = calibrationSink {
            sink(raw)
            setFaceVisible(raw != nil)
            return
        }
        setFaceVisible(raw != nil)
        guard !paused, !system.asleep, let model, axTrusted else {
            updateStatus()
            return
        }
        let now = CACurrentMediaTime()
        let windows = targets.windows(now: now)
        tracker.refresh(now: now, screens: screens, windows: windows, panes: panes)

        var reading: GazeReading?
        if let raw {
            let s = smoother.smooth(raw)
            lastSample = s
            reading = model.read(s, current: engine.facedScreen ?? tracker.focusScreen,
                                 threshold: settings.headTurn, hysteresis: HeadwaySettings.edgeHysteresis)
        }
        lastReading = reading

        var list = [HitTarget]()
        var margin: CGFloat = 24
        if settings.focusWithinScreen, case .screen(let key)? = reading?.choice, key == engine.facedScreen,
           key == tracker.focusScreen, let screen = screens.first(where: { $0.key == key }) {
            list = targets.targets(on: screen, screens: screens, now: now)
            margin = min(screen.frame.width, screen.frame.height) * 0.03
        }
        let tick = EngineTick(
            t: now, reading: reading, sinceKey: Activity.sinceKey, sinceMouse: Activity.sinceMouse,
            focusScreen: tracker.focusScreen, focusWindow: tracker.focusedWindow?.targetID,
            focusTarget: tracker.focusTarget, targets: list, hitMargin: margin
        )
        if let action = engine.step(tick) { perform(action, now: now, windows: windows) }

        if settings.showGazeDot {
            let hovered = list.first { $0.id == engine.gazedTarget }?.rect
            overlay.show(point: reading?.point, ignored: reading?.choice == .ignored, highlight: hovered,
                         waiting: engine.waiting)
        }
        if Log.debugReadings, now - lastDebugWrite > 0.2, let s = lastSample {
            lastDebugWrite = now
            debugWrite(now: now, sample: s, reading: reading, tick: tick)
        }
        updateStatus()
    }

    private func perform(_ action: EngineAction, now: Double, windows: [WindowInfo]) {
        switch action {
        case .switchScreen(let key):
            guard let screen = screens.first(where: { $0.key == key }) else { return }
            let w = focuser.switchScreen(to: screen, screens: screens, windows: windows, tracker: tracker,
                                         standard: { self.targets.isStandard($0) }, movePointer: settings.movePointer)
            Log.event("switch → \(screen.name): \(w.map { "\($0.owner) #\($0.id)" } ?? "no window")")
        case .focus(let target):
            guard let w = windows.first(where: { $0.id == target.windowID }) else { return }
            if target.kind == .pane {
                let ok = panes.focus(target, in: w, focuser: focuser)
                Log.event("pane → \(w.owner) \(target.id) \(ok ? "" : "(not found)")")
            } else if tracker.focusedWindow?.id != w.id {
                // (A pane app's sidebar resolves to its own window, which may already be focused.)
                focuser.focus(window: w)
                Log.event("window → \(w.owner) #\(w.id)")
            }
        }
        tracker.refresh(now: now, screens: screens, windows: windows, panes: panes, force: true)
    }

    private func handleClick() {
        let now = CACurrentMediaTime()
        guard settings.learnFromClicks, !paused, calibrationSink == nil, now > ignoreClicksUntil,
              let sample = lastSample, now - sample.t < 0.25, model != nil else { return }
        let p = Displays.mouseLocation()
        guard let screen = Displays.screen(containing: p, in: screens), calibratedKeys.contains(screen.key) else { return }
        accuracy.record(predicted: engine.facedScreen, actual: screen.key)
        let u = (p.x - screen.frame.minX) / screen.frame.width
        let v = (p.y - screen.frame.minY) / screen.frame.height
        store.addClick(TrainingSample(face: sample, screen: screen.key, u: u, v: v, source: .click))
        clicksSinceRefit += 1
        if clicksSinceRefit >= 10 {
            clicksSinceRefit = 0
            // Refit in place; the engine keeps its state because the screens haven't changed.
            model = GazeModel(samples: store.allSamples, screens: screens)
            learnedClicks = store.clicks.count
            saveStore()
        }
        let suggest = !store.movedScreens(current: screens).isEmpty || accuracy.suggestsRecalibration
        if suggest != suggestRecalibration {
            suggestRecalibration = suggest
            if suggest { Log.event("accuracy dropped to \(accuracy.accuracy ?? 0) — suggesting recalibration") }
        }
    }

    // MARK: Status

    private func setFaceVisible(_ v: Bool) {
        if v != faceVisible { faceVisible = v }
    }

    private func computeStatus() -> TrackingStatus {
        if !cameraAuthorized { return .needsCamera }
        if calibrationSink != nil { return .calibrating }
        if !axTrusted { return .needsAccessibility }
        if model == nil { return .needsCalibration }
        if paused { return .paused }
        if system.asleep { return .asleep }
        if let e = cameraError { return .cameraProblem(e) }
        if !camera.isRunning { return .starting }
        if !faceVisible { return .noFace }
        guard let r = lastReading else { return .starting }
        if r.choice == .ignored { return .lookingAway }
        let key = engine.facedScreen ?? r.nearest
        return .facing(screens.first { $0.key == key }?.name ?? "screen")
    }

    func updateStatus(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastUIUpdate > 0.25 else { return }
        lastUIUpdate = now
        let s = computeStatus()
        if s != status { status = s }
    }

    private func debugWrite(now: Double, sample: FaceSample, reading: GazeReading?, tick: EngineTick) {
        var d: [String: Any] = [
            "t": now, "yaw": sample.yaw, "pitch": sample.pitch, "noseX": sample.noseX, "noseY": sample.noseY,
            "eyeX": sample.eyeX, "eyeY": sample.eyeY, "faceW": sample.faceW,
            "faced": engine.facedScreen ?? "", "focus": tracker.focusScreen ?? "",
            "sinceKey": tick.sinceKey, "sinceMouse": tick.sinceMouse,
        ]
        if let r = reading {
            d["choice"] = { if case .screen(let k) = r.choice { return k } else { return "ignored" } }()
            d["progress"] = r.progress ?? -1
            d["farness"] = r.farness
            if let p = r.point { d["x"] = p.x; d["y"] = p.y }
        }
        if let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) {
            Log.reading(s)
        }
    }
}
