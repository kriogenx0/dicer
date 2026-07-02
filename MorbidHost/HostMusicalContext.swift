import AudioToolbox
import Foundation

/// Drives the `AUHostMusicalContextBlock` handed to the loaded effect, so its
/// step sequencer can sync to this host's transport. A simple wall-clock-based
/// beat clock — accurate enough for a test host, not a substitute for a real
/// DAW's sample-accurate transport.
final class HostMusicalContext {
    private static let timeSignatureNumerator = 4.0
    private static let timeSignatureDenominator = 4

    var bpm: Double = 120

    private var startTime: CFAbsoluteTime?

    func reset() {
        startTime = CFAbsoluteTimeGetCurrent()
    }

    func stop() {
        startTime = nil
    }

    func makeBlock() -> AUHostMusicalContextBlock {
        { [weak self] currentTempo, timeSigNumerator, timeSigDenominator, currentBeatPosition, sampleOffsetToNextBeat, currentMeasureDownbeatPosition in
            guard let self else { return false }
            let tempo = self.bpm
            let elapsedSeconds = self.startTime.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0
            let beats = elapsedSeconds * tempo / 60.0

            currentTempo?.pointee = tempo
            timeSigNumerator?.pointee = Self.timeSignatureNumerator
            timeSigDenominator?.pointee = Self.timeSignatureDenominator
            currentBeatPosition?.pointee = beats
            // Not computed precisely — this host doesn't have a per-buffer
            // sample count at the point this block is called. 0 is a
            // documented-valid value, not just a stub.
            sampleOffsetToNextBeat?.pointee = 0
            currentMeasureDownbeatPosition?.pointee = (beats / Self.timeSignatureNumerator).rounded(.down) * Self.timeSignatureNumerator
            return true
        }
    }
}
