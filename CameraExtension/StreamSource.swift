import CoreMediaIO
import Foundation

/// One stream on the virtual device: either the source apps read from, or
/// the sink the TZ Cam app writes into.
final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: DeviceSource
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private var client: CMIOExtensionClient?

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, owner: DeviceSource) {
        self.owner = owner
        self.format = format
        self.direction = direction
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        var props: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            props.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup])
        }
        return props
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: TZCam.frameRate)
        }
        if direction == .sink {
            if properties.contains(.streamSinkBufferQueueSize) {
                props.sinkBufferQueueSize = 1
            }
            if properties.contains(.streamSinkBuffersRequiredForStartup) {
                props.sinkBuffersRequiredForStartup = 1
            }
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        switch direction {
        case .sink:
            guard let client else { throw NSError(domain: "TZCam", code: 1) }
            owner.sinkStarted(client: client)
        default:
            owner.sourceStarted()
        }
    }

    func stopStream() throws {
        switch direction {
        case .sink:
            owner.sinkStopped()
        default:
            owner.sourceStopped()
        }
    }
}
