import CoreMediaIO
import CoreMedia
import CoreVideo
import Foundation

/// Writes frames into the TZ Cam extension's sink stream via the CoreMediaIO C API.
final class VirtualCameraSink {
    private let lock = NSLock()
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    var isConnected: Bool { lock.around { queue != nil } }

    /// Number of frames waiting in the queue, nil if not connected.
    var queueCount: Int? { lock.around { queue.map { Int(CMSimpleQueueGetCount($0)) } } }

    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        guard let device = findDevice() else { return false }
        let streams = objectIDs(of: device, selector: kCMIODevicePropertyStreams)
        // Sink streams report direction 0 (output). Fall back to the last stream.
        guard let sink = streams.first(where: { direction(of: $0) == 0 }) ?? streams.last, streams.count > 1 else { return false }

        var unmanaged: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
        guard status == noErr, let q = unmanaged?.takeRetainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else { return false }

        lock.around {
            deviceID = device
            streamID = sink
            queue = q
        }
        return true
    }

    func disconnect() {
        lock.around {
            if queue != nil { CMIODeviceStopStream(deviceID, streamID) }
            queue = nil
        }
    }

    /// False if the device has disappeared (extension replaced or removed).
    func validate() -> Bool {
        let current = lock.around { deviceID }
        return objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices).contains(current)
    }

    /// Returns true if the frame was accepted (there was room in the queue).
    @discardableResult
    func enqueue(_ pixelBuffer: CVPixelBuffer) -> Bool {
        lock.around {
            guard let q = queue, CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return false }

            var format: CMFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
                  let format else { return false }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: TZCam.frameRate),
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid
            )
            var sbuf: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sbuf
            ) == noErr, let sbuf else { return false }

            let ptr = Unmanaged.passRetained(sbuf).toOpaque()
            if CMSimpleQueueEnqueue(q, element: ptr) != noErr {
                Unmanaged<CMSampleBuffer>.fromOpaque(ptr).release()
                return false
            }
            return true
        }
    }

    // MARK: CoreMediaIO lookups

    private func findDevice() -> CMIOObjectID? {
        let target = TZCam.deviceUUID.uuidString
        for device in objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
            if uid(of: device) == target { return device }
        }
        return nil
    }

    private func address<T: BinaryInteger>(_ selector: T) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func objectIDs<T: BinaryInteger>(of object: CMIOObjectID, selector: T) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private func uid(of device: CMIOObjectID) -> String? {
        var addr = address(kCMIODevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = address(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }
}

extension NSLock {
    func around<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
