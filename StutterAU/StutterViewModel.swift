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

    private let mainParameters: [ParameterAddress: AUParameter]
    private let stepParameters: [AUParameter]

    private nonisolated(unsafe) var observerToken: AUParameterObserverToken?

    private var values: [ParameterAddress: Double]
    var stepStates: [Bool]

    var activeStepCount: Int {
        choice(PatternLength.self, at: .patternLength).stepCount
    }

    init(audioUnit: StutterAudioUnit) {
        self.audioUnit = audioUnit
        let tree = audioUnit.parameterTree!
        parameterTree = tree

        var parameters: [ParameterAddress: AUParameter] = [:]
        for address in ParameterAddress.allCases {
            parameters[address] = tree.parameter(withAddress: address.rawValue)!
        }
        mainParameters = parameters
        stepParameters = (0..<ParameterAddress.maxSteps).map { offset in
            tree.parameter(withAddress: ParameterAddress.stepBase + AUParameterAddress(offset))!
        }

        values = parameters.mapValues { Double($0.value) }
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
        if let parameter = ParameterAddress(rawValue: address) {
            values[parameter] = Double(value)
        } else if address >= ParameterAddress.stepBase, address < ParameterAddress.stepBase + AUParameterAddress(ParameterAddress.maxSteps) {
            stepStates[Int(address - ParameterAddress.stepBase)] = value >= 0.5
        }
    }

    func value(_ address: ParameterAddress) -> Double {
        values[address] ?? 0
    }

    func setValue(_ value: Double, for address: ParameterAddress) {
        values[address] = value
        mainParameters[address]?.setValue(AUValue(value), originator: observerToken)
    }

    func choice<Choice: ParameterChoice>(_ type: Choice.Type, at address: ParameterAddress) -> Choice {
        Choice(rawValue: Int(value(address).rounded())) ?? Choice.allCases.first!
    }

    func toggleStep(_ index: Int) {
        guard index >= 0, index < stepStates.count else { return }
        let newValue = !stepStates[index]
        stepStates[index] = newValue
        stepParameters[index].setValue(newValue ? 1 : 0, originator: observerToken)
    }
}
