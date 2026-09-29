import AVFoundation
import CoreVideo
import HeadwayCore
import QuartzCore
import Vision

/// Runs the webcam at 720p, at most 15 frames a second, and hands each frame to the face analyzer.
/// (1080p gave the iris finder more pixels but cost noticeably more battery for about the same result.)
/// Frames live only in memory for the few milliseconds analysis takes.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// `HEADWAY_FPS` overrides it for measurements.
    static let maxFPS = Double(ProcessInfo.processInfo.environment["HEADWAY_FPS"] ?? "") ?? 15.0
    /// Analyse every n-th frame (1 = all). Set from the main thread, read on the camera queue.
    /// `HEADWAY_EVERY_NTH` sets the starting value for measurements.
    var everyNth: Int {
        get { lock.lock(); defer { lock.unlock() }; return _everyNth }
        set { lock.lock(); _everyNth = max(1, newValue); lock.unlock() }
    }
    private var _everyNth = Int(ProcessInfo.processInfo.environment["HEADWAY_EVERY_NTH"] ?? "") ?? 1
    private let lock = NSLock()
    private var frameCounter = 0
    /// Frames the camera delivered, before Headway's own throttle (for `--diagnose`).
    private(set) var delivered = 0

    /// Called on the camera queue with each analysed frame (nil = no face found).
    var onSample: ((FaceSample?) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "headway.camera")
    private let analyzer = FaceAnalyzer()
    /// Vision's pupil estimate for the last analysed frame (camera queue only), for `--diagnose`.
    var lastVisionEye: (x: Double, y: Double)? { analyzer.lastVisionEye }
    var cpuBreakdown: (detect: Double, landmarks: Double, iris: Double, frames: Int) { analyzer.cpu }
    var computeDevices: String {
        let r = VNDetectFaceLandmarksRequest()
        guard let d = try? r.supportedComputeStageDevices else { return "?" }
        return d.map { "\($0.key.rawValue): \($0.value.map { "\($0)" })" }.joined(separator: "; ")
    }
    private var lastFrame = 0.0
    private(set) var isRunning = false
    private(set) var deviceName: String?

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static func device(id: String?) -> AVCaptureDevice? {
        let all = devices()
        if let id, let d = all.first(where: { $0.uniqueID == id }) { return d }
        return all.first { $0.deviceType == .builtInWideAngleCamera } ?? AVCaptureDevice.default(for: .video)
    }

    enum Failure: Error { case noCamera, cannotConfigure }

    func start(deviceID: String?) throws {
        guard !isRunning else { return }
        guard let device = Self.device(id: deviceID) else { throw Failure.noCamera }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw Failure.cannotConfigure
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.cannotConfigure
        }
        session.addOutput(output)
        // A session preset silently runs the camera at its full rate (30 fps). Picking the format ourselves
        // (which switches the session to "input priority") lets the lower rate stick, so the camera pipeline
        // does half the work or less. Applied again once running, in case starting resets it.
        let format = Self.format(for: device)
        applyRate(device, format)
        session.commitConfiguration()
        deviceName = device.localizedName
        isRunning = true
        queue.async {
            self.session.startRunning()
            self.applyRate(device, format)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { self.session.stopRunning() }
    }

    private func applyRate(_ device: AVCaptureDevice, _ format: AVCaptureDevice.Format?) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if let format, device.activeFormat != format { device.activeFormat = format }
        let ok = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Self.maxFPS && Self.maxFPS <= $0.maxFrameRate }
        guard ok else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.maxFPS))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.maxFPS))
    }

    /// A 1280×720 format that can run at `maxFPS` (smallest such format if 720p isn't offered).
    private static func format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= 1280 && d.height >= 720
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= maxFPS && maxFPS <= $0.maxFrameRate }
        }
        let pixels = { (f: AVCaptureDevice.Format) -> Int32 in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        return usable.min { pixels($0) < pixels($1) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        delivered += 1
        // Also throttle here, for cameras that ignore the frame-rate request.
        guard now - lastFrame >= 1 / Self.maxFPS - 0.005 else { return }
        lastFrame = now
        frameCounter += 1
        guard frameCounter % everyNth == 0, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onSample?(analyzer.analyze(buffer, t: now))
    }
}

/// Turns one camera frame into head-pose numbers with Apple's Vision framework.
final class FaceAnalyzer {
    private let rectangles = VNDetectFaceRectanglesRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()
    /// Vision's own pupil estimate from the last frame, kept only for `--diagnose` comparisons.
    private(set) var lastVisionEye: (x: Double, y: Double)?
    /// CPU seconds spent per stage, for `--diagnose` (detect, landmarks, iris, frames).
    private(set) var cpu = (detect: 0.0, landmarks: 0.0, iris: 0.0, frames: 0)

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    init() {
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
    }

    func analyze(_ buffer: CVPixelBuffer, t: Double) -> FaceSample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        cpu.frames += 1
        var t0 = Self.threadCPU()
        defer { _ = t0 }
        let detected = (try? handler.perform([rectangles])) != nil
        cpu.detect += Self.threadCPU() - t0
        t0 = Self.threadCPU()
        guard detected,
              let face = rectangles.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.boundingBox.width > 0.05
        else { return nil }
        landmarks.inputFaceObservations = [face]
        t0 = Self.threadCPU()
        let marked = (try? handler.perform([landmarks])) != nil
        cpu.landmarks += Self.threadCPU() - t0
        guard marked, let lm = landmarks.results?.first?.landmarks else { return nil }

        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.pointsInImage(imageSize: size) ?? [] }
        var contour = pts(lm.faceContour)
        var nose = pts(lm.nose)
        var leftEye = pts(lm.leftEye)
        var rightEye = pts(lm.rightEye)
        var leftPupil = pts(lm.leftPupil)
        var rightPupil = pts(lm.rightPupil)
        guard contour.count >= 3, !nose.isEmpty, !leftEye.isEmpty, !rightEye.isEmpty else { return nil }
        let visionPupils = (leftPupil, rightPupil)

        // Find each iris in the pixels ourselves; Vision's pupil landmark barely moves when only the eyes do.
        t0 = Self.threadCPU()
        if let (l, r) = irisCentres(buffer, size: size, leftEye: leftEye, rightEye: rightEye) {
            if let l { leftPupil = [l] }
            if let r { rightPupil = [r] }
        }
        cpu.iris += Self.threadCPU() - t0

        // Undo sideways head tilt so the geometry below only sees turn and nod.
        let le = centroid(leftEye), re = centroid(rightEye)
        let tilt = atan2(re.y - le.y, re.x - le.x)
        let pivot = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
        let unrotate = { (ps: inout [CGPoint]) in ps = ps.map { Self.rotate($0, around: pivot, by: -tilt) } }
        unrotate(&contour); unrotate(&nose); unrotate(&leftEye); unrotate(&rightEye)
        unrotate(&leftPupil); unrotate(&rightPupil)

        let jawLeft = contour.min { $0.x < $1.x }!.x
        let jawRight = contour.max { $0.x < $1.x }!.x
        let chin = contour.min { $0.y < $1.y }!.y   // Vision's image coordinates grow upwards
        let width = max(jawRight - jawLeft, 1)
        let noseC = centroid(nose)
        let eyeLine = (centroid(leftEye).y + centroid(rightEye).y) / 2

        func eyeOffset(_ eye: [CGPoint], _ pupil: [CGPoint]) -> (Double, Double)? {
            guard let p = pupil.first, eye.count >= 3 else { return nil }
            let minX = eye.min { $0.x < $1.x }!.x, maxX = eye.max { $0.x < $1.x }!.x
            let w = max(maxX - minX, 1)
            let c = centroid(eye)
            return (Double((p.x - minX) / w - 0.5), Double((p.y - c.y) / w))
        }
        let eyes = [eyeOffset(leftEye, leftPupil), eyeOffset(rightEye, rightPupil)].compactMap { $0 }
        let eyeX = eyes.isEmpty ? 0 : eyes.map(\.0).reduce(0, +) / Double(eyes.count)
        let eyeY = eyes.isEmpty ? 0 : eyes.map(\.1).reduce(0, +) / Double(eyes.count)
        var vl = visionPupils.0, vr = visionPupils.1
        unrotate(&vl); unrotate(&vr)
        let vEyes = [eyeOffset(leftEye, vl), eyeOffset(rightEye, vr)].compactMap { $0 }
        if vEyes.isEmpty {
            lastVisionEye = nil
        } else {
            let n = Double(vEyes.count)
            let vx: Double = vEyes.map(\.0).reduce(0, +) / n
            let vy: Double = vEyes.map(\.1).reduce(0, +) / n
            lastVisionEye = (vx, vy)
        }

        return FaceSample(
            t: t,
            yaw: face.yaw?.doubleValue ?? 0,
            pitch: face.pitch?.doubleValue ?? 0,
            roll: face.roll?.doubleValue ?? 0,
            faceX: Double(face.boundingBox.midX),
            faceY: Double(face.boundingBox.midY),
            faceW: Double(face.boundingBox.width),
            noseX: Double((noseC.x - (jawLeft + jawRight) / 2) / width),
            noseY: Double((eyeLine - noseC.y) / max(eyeLine - chin, 1)),
            eyeX: eyeX,
            eyeY: eyeY,
            confidence: Double(face.confidence)
        )
    }

    /// Iris centres in Vision's image coordinates (origin bottom-left), measured on the luma plane.
    private func irisCentres(_ buffer: CVPixelBuffer, size: CGSize, leftEye: [CGPoint], rightEye: [CGPoint])
        -> (CGPoint?, CGPoint?)? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let flip = { (p: CGPoint) in CGPoint(x: p.x, y: size.height - p.y) }
        func find(_ eye: [CGPoint]) -> CGPoint? {
            Pupil.locate(in: base, width: w, height: h, bytesPerRow: stride, outline: eye.map(flip)).map(flip)
        }
        return (find(leftEye), find(rightEye))
    }

    private func centroid(_ ps: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(ps.count, 1))
        return CGPoint(x: ps.reduce(0) { $0 + $1.x } / n, y: ps.reduce(0) { $0 + $1.y } / n)
    }

    private static func rotate(_ p: CGPoint, around c: CGPoint, by a: CGFloat) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }
}
