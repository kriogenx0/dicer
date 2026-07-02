import AudioToolbox
import Foundation

/// The stutter DSP core: a continuously-filled ring buffer, a frozen-slice
/// repeat/loop engine with independent Gate (duty-cycle) and Pitch
/// (fractional read-rate) shaping, and dry/wet mixing.
///
/// All buffer allocation happens in `prepare(sampleRate:channelCount:)`.
/// `render` never allocates — it is called from the realtime render thread.
final class StutterEngine {
    struct Parameters {
        var speedDivisionIndex: Int
        var gatePercent: Float
        var mix: Float
        var pitchSemitones: Float
        var tempo: Double
    }

    /// A step-sequencer event landing at the start of a render sub-chunk.
    struct StepTrigger {
        let isOn: Bool
    }

    private static let maxRingSeconds: Double = 4
    private static let gateRampMax = 32
    private static let pitchCrossfadeMax = 128

    private var sampleRate: Double = 44100
    private var channelCount: Int = 0
    private var ringLength: Int = 0
    private var maxSliceLength: Int = 0

    private var ringBuffers: [[Float]] = []
    private var frozenSlices: [[Float]] = []
    private var frozenSliceLength: Int = 0

    private var ringWritePos: Int = 0
    private var readPointer: Double = 0
    private var cycleSamplePos: Int = 0
    private var isActive: Bool = false

    private var inputChannelPointers: [UnsafeMutablePointer<Float>?] = []
    private var outputChannelPointers: [UnsafeMutablePointer<Float>?] = []

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        ringLength = max(Int((sampleRate * Self.maxRingSeconds).rounded()), 1)
        maxSliceLength = ringLength
        ringBuffers = (0..<self.channelCount).map { _ in [Float](repeating: 0, count: ringLength) }
        frozenSlices = (0..<self.channelCount).map { _ in [Float](repeating: 0, count: maxSliceLength) }
        inputChannelPointers = [UnsafeMutablePointer<Float>?](repeating: nil, count: self.channelCount)
        outputChannelPointers = [UnsafeMutablePointer<Float>?](repeating: nil, count: self.channelCount)
        reset()
    }

    func reset() {
        for c in 0..<ringBuffers.count {
            for i in 0..<ringBuffers[c].count { ringBuffers[c][i] = 0 }
        }
        ringWritePos = 0
        readPointer = 0
        cycleSamplePos = 0
        frozenSliceLength = 0
        isActive = false
    }

    /// Captures the most recent `cycleLength` ring-buffer samples (derived
    /// from the live Speed parameter and current tempo) as the new frozen
    /// slice, and resets playback phase. Called only at a step's start.
    private func beginNewSlice(parameters: Parameters) {
        let division = SpeedDivision(rawValue: parameters.speedDivisionIndex) ?? .sixteenth
        let clampedTempo = max(parameters.tempo, 1)
        let samples = sampleRate * 240.0 * division.noteFraction / clampedTempo
        let sliceLength = max(1, min(Int(samples.rounded()), maxSliceLength))

        for c in 0..<channelCount {
            for i in 0..<sliceLength {
                let ringIndex = Self.wrapIndex(ringWritePos - sliceLength + i, modulus: ringLength)
                frozenSlices[c][i] = ringBuffers[c][ringIndex]
            }
        }
        frozenSliceLength = sliceLength
        readPointer = 0
        cycleSamplePos = 0
        isActive = true
    }

    /// Renders `frameCount` frames starting at `frameOffset` within the
    /// supplied buffer lists, with constant parameters across the call. Pass
    /// `stepTrigger` only on the sub-chunk where a new pattern step begins.
    func render(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        frameOffset: Int,
        frameCount: Int,
        parameters: Parameters,
        stepTrigger: StepTrigger?
    ) {
        guard frameCount > 0, channelCount > 0 else { return }

        if let trigger = stepTrigger {
            if trigger.isOn {
                beginNewSlice(parameters: parameters)
            } else {
                isActive = false
            }
        }

        let activeChannelCount = min(inputBuffers.count, outputBuffers.count, channelCount)
        guard activeChannelCount > 0 else { return }
        for c in 0..<activeChannelCount {
            inputChannelPointers[c] = inputBuffers[c].mData?.assumingMemoryBound(to: Float.self)
            outputChannelPointers[c] = outputBuffers[c].mData?.assumingMemoryBound(to: Float.self)
        }

        let active = isActive && frozenSliceLength > 0
        let pitchRatio = pow(2.0, Double(parameters.pitchSemitones) / 12.0)
        let clampedGate = Double(min(max(parameters.gatePercent, 0), 100))
        let gateThreshold = Int((Double(frozenSliceLength) * clampedGate / 100.0).rounded())
        let rampSamples = max(0, min(Self.gateRampMax, gateThreshold, frozenSliceLength - gateThreshold))
        let mix = min(max(parameters.mix, 0), 1)
        let crossfadeSamples = frozenSliceLength > 0 ? min(Self.pitchCrossfadeMax, frozenSliceLength / 4) : 0

        var localReadPointer = readPointer
        var localCyclePos = cycleSamplePos
        var localRingWritePos = ringWritePos

        for i in 0..<frameCount {
            var envelope: Float = 1
            if active {
                if rampSamples > 0 {
                    if localCyclePos < gateThreshold {
                        if localCyclePos < rampSamples {
                            envelope = Float(localCyclePos) / Float(rampSamples)
                        } else if localCyclePos >= gateThreshold - rampSamples {
                            envelope = Float(gateThreshold - localCyclePos) / Float(rampSamples)
                        }
                    } else {
                        envelope = 0
                    }
                } else if localCyclePos >= gateThreshold {
                    envelope = 0
                }
            }

            for c in 0..<activeChannelCount {
                guard let inPtr = inputChannelPointers[c], let outPtr = outputChannelPointers[c] else { continue }
                let drySample = inPtr[frameOffset + i]
                ringBuffers[c][localRingWritePos] = drySample

                var processed = drySample
                if active {
                    let tail = interpolatedRead(channel: c, position: localReadPointer)
                    var sample = tail
                    if crossfadeSamples > 0, localReadPointer >= Double(frozenSliceLength - crossfadeSamples) {
                        let headPos = localReadPointer - Double(frozenSliceLength - crossfadeSamples)
                        let head = interpolatedRead(channel: c, position: headPos)
                        let fadeAmount = Float(headPos / Double(crossfadeSamples))
                        sample = tail * (1 - fadeAmount) + head * fadeAmount
                    }
                    processed = sample * envelope
                }

                outPtr[frameOffset + i] = drySample * (1 - mix) + processed * mix
            }

            localRingWritePos += 1
            if localRingWritePos >= ringLength { localRingWritePos = 0 }

            if active {
                localReadPointer += pitchRatio
                if localReadPointer >= Double(frozenSliceLength) {
                    localReadPointer -= Double(frozenSliceLength)
                }
                localCyclePos += 1
                if localCyclePos >= frozenSliceLength {
                    localCyclePos = 0
                }
            }
        }

        readPointer = localReadPointer
        cycleSamplePos = localCyclePos
        ringWritePos = localRingWritePos
    }

    private func interpolatedRead(channel: Int, position: Double) -> Float {
        let length = frozenSliceLength
        guard length > 0 else { return 0 }
        let i0 = Int(position)
        let frac = Float(position - Double(i0))
        let idx0 = i0 % length
        let idx1 = (idx0 + 1) % length
        let s0 = frozenSlices[channel][idx0]
        let s1 = frozenSlices[channel][idx1]
        return s0 + (s1 - s0) * frac
    }

    private static func wrapIndex(_ value: Int, modulus: Int) -> Int {
        let wrapped = value % modulus
        return wrapped < 0 ? wrapped + modulus : wrapped
    }
}
