import AudioToolbox
import Foundation

/// Tempo and beat position resolved for a single render call.
struct MusicalContext {
    var tempo: Double
    var beatPosition: Double
}

/// A point within a render buffer at which the engine should evaluate which
/// pattern step is active.
struct StepEntry {
    let sampleOffset: Int
    let stepIndex: Int
}

/// Tempo-synced step-grid math. Resolves the host's musical context (falling
/// back to a free-running clock when the host provides none or the tempo is
/// set in the plugin),
/// and converts it into step-grid entry points for a render buffer.
///
/// Stateless with respect to the step grid itself: phase-within-pattern is
/// always recomputed from the host's beat position, never carried forward
/// frame-to-frame, so playback stays locked through host seeks and loops.
/// The only persisted state is the free-running clock's beat position, which
/// is used when the tempo is set in the plugin or the host provides none.
final class SequencerClock {
    private static let defaultTempo = 120.0
    private static let stepsPerBar = 16
    /// Steps are sixteenth notes: 4 steps per beat, independent of the host's
    /// reported time signature (see plan scope assumption #1).
    private static let stepsPerBeat = 4.0

    private var sampleRate: Double = 44100
    private var fallbackBeatPosition: Double = 0

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        fallbackBeatPosition = 0
    }

    func reset() {
        fallbackBeatPosition = 0
    }

    /// Resolves tempo/beat position for this render call. Call exactly once
    /// per render call (or once per host-context-dependent sub-chunk group),
    /// then call `advanceFallback` with the frame count actually rendered.
    /// A `manualTempo` (Tempo: Set) overrides the host and runs the free clock.
    func resolveContext(musicalContextBlock: AUHostMusicalContextBlock?, manualTempo: Double?) -> MusicalContext {
        if let manualTempo, manualTempo > 0 {
            return MusicalContext(tempo: manualTempo, beatPosition: fallbackBeatPosition)
        }
        if let block = musicalContextBlock {
            var tempo: Double = Self.defaultTempo
            var beatPosition: Double = 0
            let ok = block(&tempo, nil, nil, &beatPosition, nil, nil)
            if ok, tempo > 0 {
                return MusicalContext(tempo: tempo, beatPosition: beatPosition)
            }
        }
        return MusicalContext(tempo: Self.defaultTempo, beatPosition: fallbackBeatPosition)
    }

    /// Must be called once per render call with the frame count actually
    /// rendered and the tempo it was rendered at, to advance the free clock.
    /// Unused while the host drives the beat, but cheap enough not to skip.
    func advanceFallback(frameCount: Int, tempo: Double) {
        fallbackBeatPosition += Double(frameCount) / sampleRate * tempo / 60.0
    }

    private func samplesPerStep(tempo: Double) -> Double {
        let clampedTempo = max(tempo, 1)
        let samplesPerBeat = sampleRate * 60.0 / clampedTempo
        return max(samplesPerBeat / Self.stepsPerBeat, 1)
    }

    /// The pattern step active at a given sample offset from the start of a
    /// render call whose musical context is `context`.
    func stepIndex(atSampleOffset offset: Int, context: MusicalContext, patternLength: PatternLength) -> Int {
        let step = samplesPerStep(tempo: context.tempo)
        let absoluteStepPosition = context.beatPosition * Self.stepsPerBeat + Double(offset) / step
        let n = Int64(floor(absoluteStepPosition))
        return Self.wrapIndex(n, modulus: patternLength.stepCount)
    }

    /// Every point within [0, frameCount) at which the engine should evaluate
    /// the active step: always offset 0 (so playback resyncs to the host's
    /// actual position every render call), plus every subsequent in-buffer
    /// step transition, sorted ascending.
    func stepEntries(context: MusicalContext, patternLength: PatternLength, frameCount: Int) -> [StepEntry] {
        guard frameCount > 0 else { return [] }
        let step = samplesPerStep(tempo: context.tempo)
        let absoluteStepPosition = context.beatPosition * Self.stepsPerBeat
        let stepCount = patternLength.stepCount

        let currentStep = Int64(floor(absoluteStepPosition))
        var entries: [StepEntry] = [StepEntry(sampleOffset: 0, stepIndex: Self.wrapIndex(currentStep, modulus: stepCount))]

        var n = currentStep + 1
        // Safety cap: at most one entry per sample, guards against pathological
        // tempo/sample-rate combinations rather than looping unbounded.
        var guardCount = 0
        while guardCount <= frameCount {
            let offsetSamples = (Double(n) - absoluteStepPosition) * step
            if offsetSamples >= Double(frameCount) {
                break
            }
            entries.append(StepEntry(sampleOffset: Int(offsetSamples.rounded()), stepIndex: Self.wrapIndex(n, modulus: stepCount)))
            n += 1
            guardCount += 1
        }
        return entries
    }

    private static func wrapIndex(_ value: Int64, modulus: Int) -> Int {
        let m = Int64(modulus)
        let wrapped = value % m
        return Int(wrapped < 0 ? wrapped + m : wrapped)
    }
}
