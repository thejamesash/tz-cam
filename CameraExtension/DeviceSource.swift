import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio

/// The virtual camera. It has two streams:
/// - a source stream that Teams/Zoom read from
/// - a sink stream the TZ Cam app writes finished frames into
///
/// Frames from the sink are forwarded to the source. When the app isn't
/// sending anything, a placeholder frame is shown instead.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: StreamSource!

    /// All mutable state below is only touched on this queue.
    private let queue = DispatchQueue(label: "tzcam.extension.device", qos: .userInteractive)
    private var formatDescription: CMFormatDescription!
    private var pool: CVPixelBufferPool!
    private var placeholder: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var streamingClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var consuming = false
    private var lastLiveFrame: Double = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: TZCam.deviceUUID,
            legacyDeviceID: TZCam.deviceUUID.uuidString,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: TZCam.width,
            height: TZCam.height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: TZCam.width,
            kCVPixelBufferHeightKey: TZCam.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)

        let frameDuration = CMTime(value: 1, timescale: TZCam.frameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )

        sourceStream = StreamSource(name: "TZ Cam Video", id: TZCam.sourceStreamUUID, direction: .source, format: format, owner: self)
        sinkStream = StreamSource(name: "TZ Cam Input", id: TZCam.sinkStreamUUID, direction: .sink, format: format, owner: self)

        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error)")
        }

        placeholder = makePlaceholder()
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "TZ Cam"
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Stream lifecycle (called by StreamSource)

    func sourceStarted() {
        queue.async {
            self.streamingClients += 1
            if self.timer == nil { self.startTimer() }
            self.pumpSink()
        }
    }

    func sourceStopped() {
        queue.async {
            self.streamingClients = max(0, self.streamingClients - 1)
            if self.streamingClients == 0 {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    func sinkStarted(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.pumpSink()
        }
    }

    func sinkStopped() {
        queue.async { self.sinkClient = nil }
    }

    // MARK: Frames

    private func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func nanos(_ seconds: Double) -> UInt64 {
        UInt64(seconds * Double(NSEC_PER_SEC))
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(TZCam.frameRate), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
        t.resume()
        timer = t
    }

    private func sendPlaceholderIfIdle() {
        guard streamingClients > 0, hostNow() - lastLiveFrame > TZCam.staleFrameSeconds, let pb = placeholder else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: TZCam.frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sbuf
        )
        guard err == noErr, let sbuf else { return }
        sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: nanos(timing.presentationTimeStamp.seconds))
    }

    /// Pull the next frame from the app. Only consumes while someone is
    /// watching, which lets the app notice idleness (its queue stays full)
    /// and turn the real camera off.
    private func pumpSink() {
        guard !consuming, streamingClients > 0, let client = sinkClient else { return }
        consuming = true
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, sequence, _, _, _ in
            guard let self else { return }
            self.queue.async {
                self.consuming = false
                guard let sbuf else {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { self.pumpSink() }
                    return
                }
                let now = self.hostNow()
                let age = now - sbuf.presentationTimeStamp.seconds
                if age < TZCam.staleFrameSeconds, self.streamingClients > 0 {
                    self.lastLiveFrame = now
                    self.sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: self.nanos(now))
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: self.nanos(now))
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
                self.pumpSink()
            }
        }
    }

    private func makePlaceholder() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let w = CGFloat(TZCam.width), h = CGFloat(TZCam.height)
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(w),
            height: Int(h),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return pb }

        ctx.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let font = CTFontCreateUIFontForLanguage(.system, 34, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 34, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.8, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Open the TZ Cam app to start video", attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: (w - bounds.width) / 2 - bounds.minX, y: (h - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        return pb
    }
}
