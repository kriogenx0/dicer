import AudioToolbox
import CoreAudioKit
import SwiftUI

final class StutterViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: StutterAudioUnit?
    private var hostingController: NSHostingController<StutterView>?

    nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try StutterAudioUnit(componentDescription: componentDescription, options: [])
        Task { @MainActor in
            self.audioUnit = unit
            self.embedViewIfPossible()
        }
        return unit
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        embedViewIfPossible()
    }

    private func embedViewIfPossible() {
        guard isViewLoaded, hostingController == nil, let audioUnit else { return }
        let viewModel = StutterViewModel(audioUnit: audioUnit)
        let hosting = NSHostingController(rootView: StutterView(viewModel: viewModel))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
        hostingController = hosting
    }
}
