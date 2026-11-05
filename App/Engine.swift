import AVFoundation
import Combine
import CoreImage

/// Ties capture, rendering and the virtual camera together, and decides when
/// the real camera should be on.
///
/// Auto on/off: the extension only pulls frames while some app (Teams) is
/// reading TZ Cam. While idle we leave one frame in the queue; when that frame
/// gets consumed, someone started watching, so we turn the camera on. Once
/// frames stop being accepted for a few seconds, we turn it off again.
final class Engine: ObservableObject {
    @Published private(set) var preview: CGImage?
    @Published private(set) var sinkConnected = false
    @Published private(set) var inUse = false
    @Published private(set) var cameraRunning = false
    @Published private(set) var segmentationStats: SegmentationStats?

    private let capture = CameraCapture()
    private let processor = FrameProcessor()
    private let sink = VirtualCameraSink()

    // Shared between the frame queue and main.
    private let lock = NSLock()
    private var renderSettings: RenderSettings
    private var lastAccepted: CFAbsoluteTime = 0

    // Frame queue only.
    private var frameCount = 0

    // Main thread only.
    private var keepCameraOn: Bool
    private var cameraID: String?
    private var previewVisible = false
    private var primed = false
    private var lastConnectAttempt: CFAbsoluteTime = 0
    private var lastValidate: CFAbsoluteTime = 0
    private var timer: Timer?

    private static let idleTimeout: CFAbsoluteTime = 3

    init(settings: AppSettings) {
        renderSettings = settings.render
        keepCameraOn = settings.keepCameraOn
        cameraID = settings.cameraID
        capture.onFrame = { [weak self] in self?.handle($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func apply(_ settings: AppSettings) {
        lock.around { renderSettings = settings.render }
        keepCameraOn = settings.keepCameraOn
        if settings.cameraID != cameraID {
            cameraID = settings.cameraID
            if cameraRunning { capture.start(deviceID: cameraID) }
        }
        tick()
    }

    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        if !visible { preview = nil }
        tick()
    }

    func shutdown() {
        timer?.invalidate()
        capture.stop()
        sink.disconnect()
    }

    // MARK: Frame path (frame queue)

    private func handle(_ input: CVPixelBuffer) {
        let settings = lock.around { renderSettings }
        guard let output = processor.render(input, settings: settings, now: Date()) else { return }

        if sink.enqueue(output) {
            lock.around { lastAccepted = CFAbsoluteTimeGetCurrent() }
        }

        frameCount += 1
        if frameCount % 3 == 0, let image = processor.makePreview(output) {
            let stats = settings.backgroundMode == .none ? nil : processor.stats
            let publishStats = frameCount % 15 == 0 || stats == nil
            DispatchQueue.main.async {
                guard self.previewVisible else { return }
                self.preview = image
                if publishStats { self.segmentationStats = stats }
            }
        }
    }

    // MARK: Control loop (main)

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()

        if !sink.isConnected {
            if now - lastConnectAttempt > 2 {
                lastConnectAttempt = now
                if sink.connect() { primed = false }
            }
        } else if now - lastValidate > 2 {
            lastValidate = now
            if !sink.validate() { sink.disconnect() }
        }

        var consumerActive = false
        if sink.isConnected {
            if cameraRunning {
                consumerActive = now - lock.around { lastAccepted } < Self.idleTimeout
            } else if let count = sink.queueCount {
                if !primed {
                    if count == 0, let blank = processor.blankFrame() { sink.enqueue(blank) }
                    primed = true
                } else if count == 0 {
                    consumerActive = true
                }
            }
        }

        let shouldRun = keepCameraOn || previewVisible || consumerActive
        if shouldRun && !cameraRunning {
            lock.around { lastAccepted = now } // grace period while the camera warms up
            capture.start(deviceID: cameraID)
            cameraRunning = true
        } else if !shouldRun && cameraRunning {
            capture.stop()
            cameraRunning = false
            primed = true // the queue is full of unconsumed frames
        }

        if sinkConnected != sink.isConnected { sinkConnected = sink.isConnected }
        if inUse != consumerActive { inUse = consumerActive }
    }
}
