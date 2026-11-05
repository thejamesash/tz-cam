import AVFoundation
import Combine
import SwiftUI

final class AppModel {
    static let shared = AppModel()

    let store = SettingsStore()
    let installer = ExtensionInstaller()
    let engine: Engine
    private var cancellable: AnyCancellable?

    private init() {
        engine = Engine(settings: store.settings)
        cancellable = store.$settings.dropFirst().sink { [weak engine] in engine?.apply($0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AppModel.shared.installer.activate()
    }

    // Keep running from the menu bar so Teams keeps getting video.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.shutdown()
    }
}

@main
struct TZCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("TZ Cam", id: "main") {
            ContentView()
                .environmentObject(model.store)
                .environmentObject(model.engine)
                .environmentObject(model.installer)
        }
        .defaultSize(width: 980, height: 560)

        MenuBarExtra("TZ Cam", systemImage: "clock") {
            MenuContent()
                .environmentObject(model.engine)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.inUse ? "Live in a call" : engine.sinkConnected ? "Ready" : "Waiting for camera extension")
        Divider()
        Button("Settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit TZ Cam") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
