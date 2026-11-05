import Foundation

/// Values shared by the host app and the camera extension. Changing the UUIDs
/// makes macOS treat the camera as a new device.
enum TZCam {
    static let deviceName = "TZ Cam"
    static let deviceUUID = UUID(uuidString: "6B0F4E52-2F7A-4C33-9C6B-6E5B2D7A9F11")!
    static let sourceStreamUUID = UUID(uuidString: "0E3A3C1D-8D55-4F0B-A3E5-3C2F9B7D1A21")!
    static let sinkStreamUUID = UUID(uuidString: "A4C9D7E2-5B61-4E8F-9A0C-7D3B2E1F6C32")!

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30

    /// Frames older than this when the extension receives them are dropped,
    /// so a frame left in the queue never shows up minutes later.
    static let staleFrameSeconds: Double = 0.5
}
