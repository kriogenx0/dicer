import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import Observation

// AVAudioUnit isn't Sendable-annotated by the SDK, but instantiate(with:options:)
// only ever calls its completion handler once, from a single background thread.
extension AVAudioUnit: @retroactive @unchecked Sendable {}

/// Owns the playback graph (`player -> Stutter effect -> mainMixer -> output`),
/// loads the AUv3 by component description (must match StutterAU/Info.plist's
/// AudioComponents entry byte-for-byte), and exposes transport controls plus
/// the extension's view controller once it's available.
@MainActor
@Observable
final class AudioEngineController {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let musicalContext = HostMusicalContext()

    private var effectAudioUnit: AVAudioUnit?
    private var demoBuffer: AVAudioPCMBuffer?

    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var statusMessage = "Loading effect…"
    private(set) var extensionViewController: NSViewController?

    var bpm: Double = 120 {
        didSet { musicalContext.bpm = bpm }
    }

    func start() {
        loadEffect()
    }

    func play() {
        guard isReady, let demoBuffer else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                statusMessage = "Engine start failed: \(error.localizedDescription)"
                return
            }
        }
        musicalContext.reset()
        playerNode.scheduleBuffer(demoBuffer, at: nil, options: .loops)
        playerNode.play()
        isPlaying = true
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        musicalContext.stop()
        isPlaying = false
    }

    private func loadEffect() {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_Effect
        description.componentSubType = Self.fourCharCode("Stut")
        description.componentManufacturer = Self.fourCharCode("Mrbd")
        description.componentFlags = 0
        description.componentFlagsMask = 0

        AVAudioUnit.instantiate(with: description, options: []) { [weak self] avAudioUnit, error in
            Task { @MainActor in
                self?.handleInstantiation(avAudioUnit: avAudioUnit, error: error)
            }
        }
    }

    private func handleInstantiation(avAudioUnit: AVAudioUnit?, error: Error?) {
        guard let avAudioUnit else {
            statusMessage = "Failed to load effect: \(error?.localizedDescription ?? "unknown error")"
            return
        }
        effectAudioUnit = avAudioUnit

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        demoBuffer = Self.makeDemoBuffer(format: format)

        engine.attach(playerNode)
        engine.attach(avAudioUnit)
        engine.connect(playerNode, to: avAudioUnit, format: format)
        engine.connect(avAudioUnit, to: engine.mainMixerNode, format: format)
        engine.prepare()

        avAudioUnit.auAudioUnit.musicalContextBlock = musicalContext.makeBlock()

        isReady = true
        statusMessage = "Ready"

        avAudioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor in
                self?.extensionViewController = viewController
            }
        }
    }

    /// A short, seamlessly-looping plucked-tone arpeggio, generated in code so
    /// the demo has no bundled asset dependency. Its own rhythm is independent
    /// of `bpm` — only the effect's step sequencer is tempo-synced.
    private static func makeDemoBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let noteInterval = 0.25
        let pitches: [Double] = [220.00, 220.00, 277.18, 220.00, 329.63, 277.18, 220.00, 164.81]
        let cycleLength = noteInterval * Double(pitches.count)
        let frameCount = AVAudioFrameCount((cycleLength * sampleRate).rounded())

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let decayRate = 12.0
        for channel in 0..<Int(format.channelCount) {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                let noteIndex = min(Int(t / noteInterval), pitches.count - 1)
                let tWithinNote = t - Double(noteIndex) * noteInterval
                let envelope = exp(-tWithinNote * decayRate)
                let sample = sin(2 * Double.pi * pitches[noteIndex] * tWithinNote) * envelope * 0.5
                data[frame] = Float(sample)
            }
        }
        return buffer
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        for scalar in string.unicodeScalars {
            code = (code << 8) + FourCharCode(scalar.value)
        }
        return code
    }
}
