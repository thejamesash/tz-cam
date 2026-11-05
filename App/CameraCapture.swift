import AVFoundation

/// Reads frames from a real camera (never TZ Cam itself).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "tzcam.session")
    private let frameQueue = DispatchQueue(label: "tzcam.frames", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.filter {
            $0.uniqueID != TZCam.deviceUUID.uuidString && $0.localizedName != TZCam.deviceName
        }
    }

    func start(deviceID: String?) {
        sessionQueue.async {
            let devices = Self.availableDevices()
            guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? devices.first else { return }

            self.session.beginConfiguration()
            if let current = self.currentInput, current.device.uniqueID != device.uniqueID {
                self.session.removeInput(current)
                self.currentInput = nil
            }
            if self.currentInput == nil,
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            }
            self.session.sessionPreset = self.session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            self.session.commitConfiguration()

            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }
}
