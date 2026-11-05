import AppKit
import CoreImage

/// Renders the time badge ("4:12 PM" over "Lisbon · Thu · UTC+0") as a CIImage
/// positioned on the canvas. Only re-renders when the text changes, so
/// roughly once a minute.
final class ClockOverlay {
    private var cacheKey = ""
    private var cached: CIImage?
    private let formatter = DateFormatter()
    private let weekdayFormatter = DateFormatter()

    init() {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.dateFormat = "EEE"
    }

    func image(now: Date, settings: RenderSettings, canvas: CGSize) -> CIImage? {
        let tz = settings.timeZone
        formatter.timeZone = tz
        weekdayFormatter.timeZone = tz
        formatter.dateFormat = settings.use24Hour ? "HH:mm" : "h:mm a"

        let time = formatter.string(from: now)
        let sub = [settings.displayLabel, weekdayFormatter.string(from: now), Self.utcOffset(tz, at: now)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let key = "\(time)|\(sub)|\(settings.corner.rawValue)|\(canvas.width)x\(canvas.height)"
        if key == cacheKey { return cached }

        cacheKey = key
        cached = render(time: time, sub: sub, corner: settings.corner, canvas: canvas)
        return cached
    }

    static func utcOffset(_ tz: TimeZone, at date: Date) -> String {
        let secs = tz.secondsFromGMT(for: date)
        let sign = secs < 0 ? "-" : "+"
        let h = abs(secs) / 3600
        let m = (abs(secs) % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }

    private func render(time: String, sub: String, corner: OverlayCorner, canvas: CGSize) -> CIImage? {
        let scale = canvas.height / 720
        let timeAttr = NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 52 * scale, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let subAttr = NSAttributedString(string: sub, attributes: [
            .font: NSFont.systemFont(ofSize: 22 * scale, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ])

        let ts = timeAttr.size(), ss = subAttr.size()
        let padX = 22 * scale, padY = 14 * scale, gap = 2 * scale
        let w = ceil(max(ts.width, ss.width) + padX * 2)
        let h = ceil(ts.height + ss.height + gap + padY * 2)

        guard let ctx = CGContext(
            data: nil,
            width: Int(w),
            height: Int(h),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let radius = 16 * scale
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        subAttr.draw(at: CGPoint(x: padX, y: padY))
        timeAttr.draw(at: CGPoint(x: padX, y: padY + ss.height + gap))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }

        // Teams crops tiles, so keep a generous margin from the edges.
        let mx = canvas.width * 0.06, my = canvas.height * 0.06
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft: x = mx; y = canvas.height - h - my
        case .topRight: x = canvas.width - w - mx; y = canvas.height - h - my
        case .bottomLeft: x = mx; y = my
        case .bottomRight: x = canvas.width - w - mx; y = my
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
