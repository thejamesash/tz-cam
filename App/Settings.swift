import Combine
import Foundation

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case none, blur, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .blur: "Blur"
        case .image: "Image"
        }
    }
}

enum EdgeQuality: String, Codable, CaseIterable, Identifiable {
    /// Use the accurate model unless this Mac can't keep up, then fall back.
    case auto, high, balanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .high: "High"
        case .balanced: "Balanced"
        }
    }
}

enum OverlayCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

/// Everything the frame renderer needs. Copied per frame, so keep it a value type.
struct RenderSettings: Codable, Equatable {
    var timeZoneID = TimeZone.current.identifier
    var label = ""
    var use24Hour = false
    var corner: OverlayCorner = .topLeft
    var backgroundMode: BackgroundMode = .none
    var blurRadius: Double = 18
    var backgroundImagePath: String?
    var edgeQuality: EdgeQuality = .auto

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// The label if set, otherwise the city from the zone ID ("America/New_York" -> "New York").
    var displayLabel: String {
        if !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        let city = timeZoneID.split(separator: "/").last.map(String.init) ?? timeZoneID
        return city.replacingOccurrences(of: "_", with: " ")
    }
}

struct AppSettings: Codable, Equatable {
    var render = RenderSettings()
    /// AVCaptureDevice.uniqueID, nil = first available camera.
    var cameraID: String?
    /// Keep the real camera running even when no app is using TZ Cam.
    var keepCameraOn = false
}

final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"

    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
