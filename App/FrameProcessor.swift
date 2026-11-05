import CoreImage
import CoreVideo
import QuartzCore
import Vision

/// Measured segmentation performance, shown in the UI.
struct SegmentationStats: Equatable {
    var quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    var milliseconds: Double = 0

    var description: String {
        let name = quality == .accurate ? "High" : "Balanced"
        return String(format: "Edges: %@ · %.0f ms/frame", name, milliseconds)
    }
}

/// Camera frame in, finished 1280x720 frame out:
/// person segmentation -> mask refinement -> background (blur/image) -> clock badge.
final class FrameProcessor {
    let outputSize = CGSize(width: CGFloat(TZCam.width), height: CGFloat(TZCam.height))
    let context = CIContext(options: [.cacheIntermediates: false, .name: "TZCam"])
    private(set) var stats = SegmentationStats()

    private let clock = ClockOverlay()
    private let sequenceHandler = VNSequenceRequestHandler()
    // Separate requests because they are stateful (temporal smoothing across frames).
    private let accurateRequest = FrameProcessor.makeRequest(.accurate)
    private let balancedRequest = FrameProcessor.makeRequest(.balanced)

    /// Auto mode starts on the accurate model and drops to balanced if this
    /// machine can't run it inside the frame budget.
    private var autoUsesAccurate = true
    private var accurateFrames = 0
    private var accurateAverage: Double = 0
    private static let warmupFrames = 30
    private static let accurateBudget: Double = 0.022 // seconds, leaves ~11 ms of a 30 fps frame for compositing

    /// Previous refined mask, for light temporal smoothing against flicker.
    private var previousMask: CVPixelBuffer?
    private var maskPool: CVPixelBufferPool?
    private var maskPoolSize: CGSize = .zero
    private static let maskSmoothing = 0.25 // weight of the previous frame

    private var pool: CVPixelBufferPool?
    private var backgroundCache: (path: String, image: CIImage)?

    init() {
        pool = Self.makePool(width: Int(TZCam.width), height: Int(TZCam.height), format: kCVPixelFormatType_32BGRA)
    }

    private var outputRect: CGRect { CGRect(origin: .zero, size: outputSize) }

    func render(_ input: CVPixelBuffer, settings: RenderSettings, now: Date) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: input)
        let fill = Self.aspectFill(source.extent, into: outputSize)
        let camera = source.transformed(by: fill).cropped(to: outputRect)

        var frame = camera
        if settings.backgroundMode != .none,
           let mask = personMask(input, source: source, quality: settings.edgeQuality)?
               .transformed(by: fill)
               .cropped(to: outputRect) {
            let background = background(for: settings, camera: camera)
            frame = camera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask,
            ])
        } else {
            previousMask = nil
        }

        if let badge = clock.image(now: now, settings: settings, canvas: outputSize) {
            frame = badge.composited(over: frame)
        }

        guard let out = makeBuffer() else { return nil }
        context.render(frame.cropped(to: outputRect), to: out, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    func makePreview(_ buffer: CVPixelBuffer) -> CGImage? {
        context.createCGImage(CIImage(cvPixelBuffer: buffer), from: outputRect)
    }

    /// A black frame, used to prime the virtual camera's queue.
    func blankFrame() -> CVPixelBuffer? {
        guard let pb = makeBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    // MARK: Segmentation

    private static func makeRequest(_ level: VNGeneratePersonSegmentationRequest.QualityLevel) -> VNGeneratePersonSegmentationRequest {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = level
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }

    /// Person mask at the camera's resolution, edges snapped to the camera image.
    private func personMask(_ input: CVPixelBuffer, source: CIImage, quality: EdgeQuality) -> CIImage? {
        let useAccurate: Bool
        switch quality {
        case .auto: useAccurate = autoUsesAccurate
        case .high: useAccurate = true
        case .balanced: useAccurate = false
        }
        let request = useAccurate ? accurateRequest : balancedRequest

        let start = CACurrentMediaTime()
        do {
            try sequenceHandler.perform([request], on: input)
        } catch {
            return nil
        }
        let elapsed = CACurrentMediaTime() - start
        recordTiming(elapsed, accurate: useAccurate, auto: quality == .auto)

        guard let raw = request.results?.first?.pixelBuffer else { return nil }
        let smoothed = smooth(raw)

        // Joint-bilateral upsample: uses the camera image as a guide so the
        // low-res mask's edges follow hair and shoulders instead of blurring.
        return source.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": smoothed,
            "inputSpatialSigma": 3.0,
            "inputLumaSigma": 0.15,
        ])
    }

    private func recordTiming(_ seconds: Double, accurate: Bool, auto: Bool) {
        stats.quality = accurate ? .accurate : .balanced
        stats.milliseconds = stats.milliseconds * 0.9 + seconds * 1000 * 0.1

        guard auto, accurate else { return }
        accurateFrames += 1
        guard accurateFrames > Self.warmupFrames else { return } // first frames include model load
        accurateAverage = accurateAverage == 0 ? seconds : accurateAverage * 0.9 + seconds * 0.1
        if accurateFrames > Self.warmupFrames * 2, accurateAverage > Self.accurateBudget {
            autoUsesAccurate = false
            previousMask = nil
        }
    }

    /// Blend a little of the previous mask into this one to stop edge flicker.
    private func smooth(_ raw: CVPixelBuffer) -> CIImage {
        let current = CIImage(cvPixelBuffer: raw)
        let size = current.extent.size
        if size != maskPoolSize {
            maskPool = Self.makePool(width: Int(size.width), height: Int(size.height), format: kCVPixelFormatType_OneComponent8)
            maskPoolSize = size
            previousMask = nil
        }

        var blended = current
        if let previous = previousMask {
            blended = current.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: CIImage(cvPixelBuffer: previous),
                kCIInputTimeKey: Self.maskSmoothing,
            ])
        }

        // Render so the next frame blends against a stable copy (Vision reuses its buffers).
        guard let maskPool, let stored = Self.buffer(from: maskPool) else { return current }
        context.render(blended, to: stored)
        previousMask = stored
        return CIImage(cvPixelBuffer: stored)
    }

    // MARK: Background

    private func background(for settings: RenderSettings, camera: CIImage) -> CIImage {
        switch settings.backgroundMode {
        case .image:
            if let path = settings.backgroundImagePath, let image = loadBackground(path) {
                return image
            }
            fallthrough
        case .blur:
            return camera.clampedToExtent()
                .applyingGaussianBlur(sigma: settings.blurRadius)
                .cropped(to: outputRect)
        case .none:
            return camera
        }
    }

    private func loadBackground(_ path: String) -> CIImage? {
        if let cache = backgroundCache, cache.path == path { return cache.image }
        guard let raw = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        let image = raw.transformed(by: Self.aspectFill(raw.extent, into: outputSize)).cropped(to: outputRect)
        backgroundCache = (path, image)
        return image
    }

    // MARK: Buffers

    private func makeBuffer() -> CVPixelBuffer? {
        pool.flatMap(Self.buffer(from:))
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private static func makePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
        return pool
    }

    /// Scale-to-fill and center `extent` inside a canvas of `size` at the origin.
    static func aspectFill(_ extent: CGRect, into size: CGSize) -> CGAffineTransform {
        let scale = max(size.width / extent.width, size.height / extent.height)
        let w = extent.width * scale, h = extent.height * scale
        return CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
    }
}
