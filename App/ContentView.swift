import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var installer: ExtensionInstaller
    @State private var cameras: [AVCaptureDevice] = []

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                Label(statusText, systemImage: engine.inUse ? "dot.radiowaves.left.and.right" : "video")
                    .foregroundStyle(engine.inUse ? .green : .secondary)
                Text(installer.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let stats = engine.segmentationStats {
                    Text(stats.description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                    Text("Camera access is off. Enable it in System Settings › Privacy & Security › Camera.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .frame(minWidth: 520)

            Form {
                clockSection
                backgroundSection
                cameraSection
            }
            .formStyle(.grouped)
            .frame(width: 360)
        }
        .onAppear {
            cameras = CameraCapture.availableDevices()
            engine.setPreviewVisible(true)
        }
        .onDisappear { engine.setPreviewVisible(false) }
    }

    private var statusText: String {
        if engine.inUse { return "Live: an app is using TZ Cam" }
        if engine.sinkConnected { return "Ready. Choose “TZ Cam” as your camera in Teams." }
        return "Waiting for the TZ Cam camera extension…"
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black)
            if let image = engine.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    // MARK: Sections

    private var clockSection: some View {
        Section("Clock") {
            Picker("Time zone", selection: $store.settings.render.timeZoneID) {
                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
            }
            TextField("Label", text: $store.settings.render.label, prompt: Text(store.settings.render.displayLabel))
            Toggle("24-hour time", isOn: $store.settings.render.use24Hour)
            Picker("Position", selection: $store.settings.render.corner) {
                ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var backgroundSection: some View {
        Section {
            Picker("Background", selection: $store.settings.render.backgroundMode) {
                ForEach(BackgroundMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if store.settings.render.backgroundMode != .none {
                Picker("Edge quality", selection: $store.settings.render.edgeQuality) {
                    ForEach(EdgeQuality.allCases) { Text($0.title).tag($0) }
                }
            }
            if store.settings.render.backgroundMode == .blur {
                Slider(value: $store.settings.render.blurRadius, in: 4...40) { Text("Blur") }
            }
            if store.settings.render.backgroundMode == .image {
                HStack {
                    Text(store.settings.render.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseImage)
                }
            }
        } header: {
            Text("Background")
        } footer: {
            Text("Turn off background effects in Teams so they don't stack on top of these.")
        }
    }

    private var cameraSection: some View {
        Section {
            Picker("Camera", selection: $store.settings.cameraID) {
                Text("Default").tag(String?.none)
                ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            Toggle("Keep camera on when not in a call", isOn: $store.settings.keepCameraOn)
            Button("Reinstall camera extension") { installer.activate() }
        } header: {
            Text("Camera")
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TZCam", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("background-\(UUID().uuidString).\(url.pathExtension)")

        do {
            try fm.copyItem(at: url, to: dest)
            if let old = store.settings.render.backgroundImagePath { try? fm.removeItem(atPath: old) }
            store.settings.render.backgroundImagePath = dest.path
            store.settings.render.backgroundMode = .image
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
