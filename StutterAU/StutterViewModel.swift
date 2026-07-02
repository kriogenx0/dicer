import AudioToolbox
import Observation

/// Observable bridge between the AU's parameter tree and SwiftUI. Looks up
/// each parameter by address once, and mirrors the tree's live values into
/// plain properties the view can read directly.
@MainActor
@Observable
final class StutterViewModel {
    private let audioUnit: StutterAudioUnit
    private nonisolated(unsafe) let parameterTree: AUParameterTree

    private let speedParameter: AUParameter
    private let gateParameter: AUParameter
    private let mixParameter: AUParameter
    private let pitchParameter: AUParameter
    private let patternLengthParameter: AUParameter
    private let stepParameters: [AUParameter]

    private nonisolated(unsafe) var observerToken: AUParameterObserverToken?

    var speedIndex: Int
    var gatePercent: Double
    var mix: Double
    var pitchSemitones: Double
    var patternLengthIndex: Int
    var stepStates: [Bool]

    var activeStepCount: Int {
        (PatternLength(rawValue: patternLengthIndex) ?? .oneBar).stepCount
    }

    init(audioUnit: StutterAudioUnit) {
        self.audioUnit = audioUnit
        let tree = audioUnit.parameterTree!
        parameterTree = tree

        speedParameter = tree.parameter(withAddress: ParameterAddress.speed.rawValue)!
        gateParameter = tree.parameter(withAddress: ParameterAddress.gate.rawValue)!
        mixParameter = tree.parameter(withAddress: ParameterAddress.mix.rawValue)!
        pitchParameter = tree.parameter(withAddress: ParameterAddress.pitch.rawValue)!
        patternLengthParameter = tree.parameter(withAddress: ParameterAddress.patternLength.rawValue)!
        stepParameters = (0..<ParameterAddress.maxSteps).map { offset in
            tree.parameter(withAddress: ParameterAddress.stepBase + AUParameterAddress(offset))!
        }

        speedIndex = Int(speedParameter.value)
        gatePercent = Double(gateParameter.value)
        mix = Double(mixParameter.value)
        pitchSemitones = Double(pitchParameter.value)
        patternLengthIndex = Int(patternLengthParameter.value)
        stepStates = stepParameters.map { $0.value >= 0.5 }

        observerToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
            Task { @MainActor in
                self?.handleParameterChange(address: address, value: value)
            }
        })
    }

    deinit {
        if let observerToken {
            parameterTree.removeParameterObserver(observerToken)
        }
    }

    private func handleParameterChange(address: AUParameterAddress, value: AUValue) {
        switch address {
        case ParameterAddress.speed.rawValue:
            speedIndex = Int(value)
        case ParameterAddress.gate.rawValue:
            gatePercent = Double(value)
        case ParameterAddress.mix.rawValue:
            mix = Double(value)
        case ParameterAddress.pitch.rawValue:
            pitchSemitones = Double(value)
        case ParameterAddress.patternLength.rawValue:
            patternLengthIndex = Int(value)
        default:
            if address >= ParameterAddress.stepBase, address < ParameterAddress.stepBase + AUParameterAddress(ParameterAddress.maxSteps) {
                stepStates[Int(address - ParameterAddress.stepBase)] = value >= 0.5
            }
        }
    }

    func setSpeedIndex(_ index: Int) {
        speedIndex = index
        speedParameter.setValue(AUValue(index), originator: observerToken)
    }

    func setGatePercent(_ percent: Double) {
        gatePercent = percent
        gateParameter.setValue(AUValue(percent), originator: observerToken)
    }

    func setMix(_ value: Double) {
        mix = value
        mixParameter.setValue(AUValue(value), originator: observerToken)
    }

    func setPitchSemitones(_ semitones: Double) {
        pitchSemitones = semitones
        pitchParameter.setValue(AUValue(semitones), originator: observerToken)
    }

    func setPatternLengthIndex(_ index: Int) {
        patternLengthIndex = index
        patternLengthParameter.setValue(AUValue(index), originator: observerToken)
    }

    func toggleStep(_ index: Int) {
        guard index >= 0, index < stepStates.count else { return }
        let newValue = !stepStates[index]
        stepStates[index] = newValue
        stepParameters[index].setValue(newValue ? 1 : 0, originator: observerToken)
    }
}
