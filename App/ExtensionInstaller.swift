import Foundation
import SystemExtensions

/// Activates (installs or updates) the embedded camera extension.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = "Not installed yet"

    private var identifier: String { (Bundle.main.bundleIdentifier ?? "net.jamesash.TZCam") + ".CameraExtension" }

    func activate() {
        status = "Installing camera extension…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        status = "Removing camera extension…"
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve TZ Cam in System Settings › General › Login Items & Extensions › Camera Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: status = "Camera extension installed"
        case .willCompleteAfterReboot: status = "Restart your Mac to finish installing"
        @unknown default: status = "Camera extension: \(result.rawValue)"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == OSSystemExtensionErrorDomain, nsError.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            status = "Move TZ Cam to /Applications, then reopen it"
        } else {
            status = "Extension error: \(error.localizedDescription)"
        }
    }
}
