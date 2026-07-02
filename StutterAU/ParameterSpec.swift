import AudioToolbox

/// Stable parameter addresses. Never derive these from array index — hosts may
/// persist automation by address across sessions.
enum ParameterAddress: AUParameterAddress {
    case speed = 0
    case gate = 1
    case mix = 2
    case pitch = 3
    case patternLength = 4

    /// step0...step127 occupy a contiguous block starting at 100.
    static let stepBase: AUParameterAddress = 100
    static let maxSteps = 128
}

/// Musical note divisions selectable for Speed, tempo-synced.
enum SpeedDivision: Int, CaseIterable {
    case quarter = 0
    case eighth = 1
    case sixteenth = 2
    case thirtySecond = 3
    case sixtyFourth = 4

    var displayName: String {
        switch self {
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .thirtySecond: return "1/32"
        case .sixtyFourth: return "1/64"
        }
    }

    /// Fraction of a whole note (4 beats at 4/4) this division represents.
    var noteFraction: Double {
        switch self {
        case .quarter: return 1.0 / 4.0
        case .eighth: return 1.0 / 8.0
        case .sixteenth: return 1.0 / 16.0
        case .thirtySecond: return 1.0 / 32.0
        case .sixtyFourth: return 1.0 / 64.0
        }
    }
}

/// Selectable trigger-pattern lengths, each bar fixed at 16 steps.
enum PatternLength: Int, CaseIterable {
    case oneBar = 0
    case twoBars = 1
    case fourBars = 2
    case eightBars = 3

    var displayName: String {
        switch self {
        case .oneBar: return "1 Bar"
        case .twoBars: return "2 Bars"
        case .fourBars: return "4 Bars"
        case .eightBars: return "8 Bars"
        }
    }

    static let stepsPerBar = 16

    var barCount: Int {
        switch self {
        case .oneBar: return 1
        case .twoBars: return 2
        case .fourBars: return 4
        case .eightBars: return 8
        }
    }

    /// Number of active steps in the grid for this pattern length. Looked up
    /// here once, shared by both the engine and the view model.
    var stepCount: Int {
        barCount * Self.stepsPerBar
    }
}

enum ParameterSpec {
    static func buildParameterTree() -> AUParameterTree {
        let speed = AUParameterTree.createParameter(
            withIdentifier: "speed",
            name: "Speed",
            address: ParameterAddress.speed.rawValue,
            min: 0,
            max: AUValue(SpeedDivision.allCases.count - 1),
            unit: .indexed,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: SpeedDivision.allCases.map { $0.displayName },
            dependentParameters: nil
        )
        speed.value = AUValue(SpeedDivision.sixteenth.rawValue)

        let gate = AUParameterTree.createParameter(
            withIdentifier: "gate",
            name: "Gate",
            address: ParameterAddress.gate.rawValue,
            min: 0,
            max: 100,
            unit: .percent,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil,
            dependentParameters: nil
        )
        gate.value = 100

        let mix = AUParameterTree.createParameter(
            withIdentifier: "mix",
            name: "Mix",
            address: ParameterAddress.mix.rawValue,
            min: 0,
            max: 1,
            unit: .generic,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil,
            dependentParameters: nil
        )
        mix.value = 1.0

        let pitch = AUParameterTree.createParameter(
            withIdentifier: "pitch",
            name: "Pitch",
            address: ParameterAddress.pitch.rawValue,
            min: -24,
            max: 24,
            unit: .relativeSemiTones,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil,
            dependentParameters: nil
        )
        pitch.value = 0

        let patternLength = AUParameterTree.createParameter(
            withIdentifier: "patternLength",
            name: "Pattern Length",
            address: ParameterAddress.patternLength.rawValue,
            min: 0,
            max: AUValue(PatternLength.allCases.count - 1),
            unit: .indexed,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: PatternLength.allCases.map { $0.displayName },
            dependentParameters: nil
        )
        patternLength.value = AUValue(PatternLength.oneBar.rawValue)

        var stepParameters: [AUParameter] = []
        stepParameters.reserveCapacity(ParameterAddress.maxSteps)
        for i in 0..<ParameterAddress.maxSteps {
            let step = AUParameterTree.createParameter(
                withIdentifier: "step\(i)",
                name: "Step \(i + 1)",
                address: ParameterAddress.stepBase + AUParameterAddress(i),
                min: 0,
                max: 1,
                unit: .boolean,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil,
                dependentParameters: nil
            )
            step.value = 0
            stepParameters.append(step)
        }

        let mainGroup = AUParameterTree.createGroup(
            withIdentifier: "main",
            name: "Main",
            children: [speed, gate, mix, pitch, patternLength]
        )
        let stepsGroup = AUParameterTree.createGroup(
            withIdentifier: "steps",
            name: "Steps",
            children: stepParameters
        )

        return AUParameterTree.createTree(withChildren: [mainGroup, stepsGroup])
    }
}
