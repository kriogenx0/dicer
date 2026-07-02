import AppKit
import SwiftUI

/// Bridges the AUv3's own `NSViewController` (obtained asynchronously from
/// `AUAudioUnit.requestViewController`) into SwiftUI.
struct AUViewContainer: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        viewController
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        // The extension's view controller manages its own content.
    }
}
