import AudioToolbox
import AVFoundation
import Observation

/// Pulls looped demo audio and feeds it through `StutterAudioUnit`'s render
/// block on the realtime audio thread. Kept separate from the @MainActor
/// controller so this state has no actor isolation for the render closure to
/// cross — the same reasoning as the plain-scalar parameter storage in
/// StutterAudioUnit itself.
private final class DemoPlaybackSource: @unchecked Sendable {
    private let demoBuffer: AVAudioPCMBuffer
    private let renderBlock: AUInternalRenderBlock
    private var readPosition: AVAudioFrameCount = 0
    var isPlaying = false

    init(demoBuffer: AVAudioPCMBuffer, renderBlock: @escaping AUInternalRenderBlock) {
        self.demoBuffer = demoBuffer
        self.renderBlock = renderBlock
    }

    func reset() {
        readPosition = 0
    }

    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard isPlaying else {
            silence(audioBufferList)
            isSilence.pointee = true
            return noErr
        }
        isSilence.pointee = false

        var actionFlags: AudioUnitRenderActionFlags = []
        let pullInput: AURenderPullInputBlock = { [self] _, _, frameCount, _, inputData in
            self.fill(inputData, frameCount: frameCount)
            return noErr
        }
        return renderBlock(&actionFlags, timestamp, frameCount, 0, audioBufferList, nil, pullInput)
    }

    private func fill(_ abl: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
        let destination = UnsafeMutableAudioBufferListPointer(abl)
        let source = UnsafeMutableAudioBufferListPointer(demoBuffer.mutableAudioBufferList)
        let totalFrames = demoBuffer.frameLength
        guard totalFrames > 0 else { return }
        let bytesPerFrame = MemoryLayout<Float>.size

        var framesWritten: AVAudioFrameCount = 0
        while framesWritten < frameCount {
            let framesRemaining = totalFrames - readPosition
            let framesToCopy = min(frameCount - framesWritten, framesRemaining)
            for channel in 0..<destination.count {
                guard let dst = destination[channel].mData, let src = source[channel].mData else { continue }
                memcpy(
                    dst.advanced(by: Int(framesWritten) * bytesPerFrame),
                    src.advanced(by: Int(readPosition) * bytesPerFrame),
                    Int(framesToCopy) * bytesPerFrame
                )
            }
            readPosition += framesToCopy
            framesWritten += framesToCopy
            if readPosition >= totalFrames { readPosition = 0 }
        }
    }

    private func silence(_ abl: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(abl) {
            if let mData = buffer.mData {
                memset(mData, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}

/// Owns the playback graph. Constructs `StutterAudioUnit` directly via its
/// designated initializer rather than through AudioComponent registration —
/// this app never needs the OS to discover the effect, since it names the
/// concrete Swift type itself, so it skips AVAudioUnit/AUAudioUnit's registry
/// lookup entirely and drives the render block from a plain AVAudioSourceNode.
@MainActor
@Observable
final class AudioEngineController {
    private let engine = AVAudioEngine()
    private let musicalContext = HostMusicalContext()

    private var stutterAudioUnit: StutterAudioUnit?
    private var playbackSource: DemoPlaybackSource?

    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var statusMessage = "Loading effect…"
    private(set) var stutterViewModel: StutterViewModel?

    var bpm: Double = 120 {
        didSet { musicalContext.bpm = bpm }
    }

    func start() {
        loadEffect()
    }

    func play() {
        guard isReady, let playbackSource else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                statusMessage = "Engine start failed: \(error.localizedDescription)"
                return
            }
        }
        musicalContext.reset()
        playbackSource.reset()
        playbackSource.isPlaying = true
        isPlaying = true
    }

    func stop() {
        playbackSource?.isPlaying = false
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

        do {
            let stutterAudioUnit = try StutterAudioUnit(componentDescription: description, options: [])
            try setUpEngine(with: stutterAudioUnit)
        } catch {
            statusMessage = "Failed to load effect: \(error.localizedDescription)"
        }
    }

    private func setUpEngine(with stutterAudioUnit: StutterAudioUnit) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let demoBuffer = Self.makeDemoBuffer(format: format) else {
            statusMessage = "Failed to build demo buffer"
            return
        }

        stutterAudioUnit.maximumFramesToRender = 4096
        stutterAudioUnit.musicalContextBlock = musicalContext.makeBlock()
        try stutterAudioUnit.allocateRenderResources()
        self.stutterAudioUnit = stutterAudioUnit

        let playbackSource = DemoPlaybackSource(demoBuffer: demoBuffer, renderBlock: stutterAudioUnit.internalRenderBlock)
        self.playbackSource = playbackSource

        let sourceNode = Self.makeSourceNode(format: format, playbackSource: playbackSource)

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()

        stutterViewModel = StutterViewModel(audioUnit: stutterAudioUnit)
        isReady = true
        statusMessage = "Ready"
    }

    /// Built outside the main actor on purpose: a closure formed inside a
    /// @MainActor method inherits that isolation, and Swift 6 then asserts it
    /// runs on the main queue, which traps on the realtime render thread.
    private nonisolated static func makeSourceNode(
        format: AVAudioFormat,
        playbackSource: DemoPlaybackSource
    ) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, audioBufferList in
            playbackSource.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, audioBufferList: audioBufferList)
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
