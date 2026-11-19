import AudioToolbox
import Foundation

/// Stable parameter addresses. Never derive these from array index — hosts may
/// persist automation by address across sessions.
enum ParameterAddress: AUParameterAddress, CaseIterable {
    /// The note length used when Rate is Sync. Identifier stays "speed" for saved automation.
    case speed = 0
    case gate = 1
    case mix = 2
    case pitch = 3
    case patternLength = 4
    /// While on, every step fires the stutter regardless of the pattern.
    case trigger = 5
    /// Sync (note length at the tempo) or Free (a frequency in Hz).
    case rateMode = 6
    /// The repeat frequency used when Rate is Free.
    case rate = 7
    /// Host (follow the host's tempo) or Set (use the BPM parameter).
    case tempoSource = 8
    /// The tempo used when Tempo is Set.
    case bpm = 9

    /// step0...step127 occupy a contiguous block starting at 100.
    static let stepBase: AUParameterAddress = 100
    static let maxSteps = 128
}

/// A parameter with a few named options, stored as its index.
protocol ParameterChoice: CaseIterable, RawRepresentable where RawValue == Int, AllCases: RandomAccessCollection {
    var displayName: String { get }
}

/// Musical note divisions selectable for the stutter's repeat length, tempo-synced.
enum SpeedDivision: Int, ParameterChoice {
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
enum PatternLength: Int, ParameterChoice {
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

/// How the stutter's repeat length is set.
enum RateMode: Int, ParameterChoice {
    case sync = 0
    case free = 1

    var displayName: String {
        switch self {
        case .sync: return "Sync"
        case .free: return "Free"
        }
    }

    /// Length of one repeat. Sync: the note length at `tempo`. Free: one period of `rateHz`.
    static func repeatSeconds(mode: RateMode, division: SpeedDivision, tempo: Double, rateHz: Double) -> Double {
        switch mode {
        case .sync: return 240.0 * division.noteFraction / max(tempo, 1)
        case .free: return 1.0 / max(rateHz, KnobSpec.rate.range.lowerBound)
        }
    }
}

/// Where the tempo comes from.
enum TempoSource: Int, ParameterChoice {
    case host = 0
    case set = 1

    var displayName: String {
        switch self {
        case .host: return "Host"
        case .set: return "Set"
        }
    }
}

/// Range, default and display format for a continuous parameter. The
/// parameter tree and the knob both read from here, so they can't disagree.
struct KnobSpec {
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Arrow-key and scroll step, in parameter units. Logarithmic knobs step
    /// by 1% of their travel instead.
    let step: Double
    /// Multiplier from parameter units to display units (0...1 shown as 0...100%).
    let displayScale: Double
    let unitSuffix: String
    let showsSign: Bool
    /// Frequency-like ranges spread evenly by ratio, so the low end isn't cramped.
    var isLogarithmic = false

    private static let logarithmicStep = 0.01

    /// Bipolar knobs fill their arc from the center.
    var isBipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }

    func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Position along the knob's travel, 0...1.
    func normalized(_ value: Double) -> Double {
        let low = range.lowerBound, high = range.upperBound
        guard high > low else { return 0 }
        if isLogarithmic { return log(clamped(value) / low) / log(high / low) }
        return (clamped(value) - low) / (high - low)
    }

    func value(atNormalized position: Double) -> Double {
        let position = min(max(position, 0), 1)
        let low = range.lowerBound, high = range.upperBound
        if isLogarithmic { return low * pow(high / low, position) }
        return low + position * (high - low)
    }

    /// `value` moved by `steps` arrow-key steps.
    func stepped(_ value: Double, by steps: Double) -> Double {
        if isLogarithmic { return self.value(atNormalized: normalized(value) + steps * Self.logarithmicStep) }
        return clamped(value + steps * step)
    }

    func format(_ value: Double) -> String {
        let shown = value * displayScale
        let isWhole = abs(shown - shown.rounded()) < 0.05
        let number = String(format: "%\(showsSign && shown.rounded() != 0 ? "+" : "").\(isWhole ? 0 : 1)f", isWhole ? shown.rounded() : shown)
        return number + unitSuffix
    }

    /// Accepts typed text with or without units ("50%", "50", "+3 st").
    /// Returns nil when there's no number, so the value stays unchanged.
    func parse(_ text: String) -> Double? {
        let numeric = text.filter { "0123456789.-+".contains($0) }
        guard let shown = Double(numeric) else { return nil }
        return clamped(shown / displayScale)
    }

    static let gate = KnobSpec(range: 0...100, defaultValue: 100, step: 1, displayScale: 1, unitSuffix: "%", showsSign: false)
    static let mix = KnobSpec(range: 0...1, defaultValue: 1, step: 0.01, displayScale: 100, unitSuffix: "%", showsSign: false)
    static let pitch = KnobSpec(range: -24...24, defaultValue: 0, step: 1, displayScale: 1, unitSuffix: " st", showsSign: true)
    static let rate = KnobSpec(range: 0.5...64, defaultValue: 8, step: 0, displayScale: 1, unitSuffix: " Hz", showsSign: false, isLogarithmic: true)
    static let bpm = KnobSpec(range: 20...300, defaultValue: 120, step: 1, displayScale: 1, unitSuffix: " BPM", showsSign: false)
}

enum ParameterSpec {
    static func buildParameterTree() -> AUParameterTree {
        let main: [AUParameter] = [
            choice(.speed, "speed", "Note Length", SpeedDivision.self, default: .sixteenth),
            knob(.gate, "gate", "Gate", .gate, unit: .percent),
            knob(.mix, "mix", "Mix", .mix, unit: .generic),
            knob(.pitch, "pitch", "Pitch", .pitch, unit: .relativeSemiTones),
            choice(.patternLength, "patternLength", "Pattern Length", PatternLength.self, default: .oneBar),
            toggle(.trigger, "trigger", "Trigger"),
            choice(.rateMode, "rateMode", "Rate Mode", RateMode.self, default: .sync),
            knob(.rate, "rate", "Rate", .rate, unit: .hertz),
            choice(.tempoSource, "tempoSource", "Tempo Source", TempoSource.self, default: .host),
            knob(.bpm, "bpm", "BPM", .bpm, unit: .BPM),
        ]

        let steps = (0..<ParameterAddress.maxSteps).map { i in
            makeParameter(
                identifier: "step\(i)", name: "Step \(i + 1)",
                address: ParameterAddress.stepBase + AUParameterAddress(i),
                range: 0...1, unit: .boolean, canRamp: false, valueStrings: nil, initialValue: 0
            )
        }

        return AUParameterTree.createTree(withChildren: [
            AUParameterTree.createGroup(withIdentifier: "main", name: "Main", children: main),
            AUParameterTree.createGroup(withIdentifier: "steps", name: "Steps", children: steps),
        ])
    }

    private static func knob(_ address: ParameterAddress, _ identifier: String, _ name: String, _ spec: KnobSpec, unit: AudioUnitParameterUnit) -> AUParameter {
        makeParameter(
            identifier: identifier, name: name, address: address.rawValue,
            range: spec.range, unit: unit, canRamp: true, valueStrings: nil, initialValue: spec.defaultValue
        )
    }

    private static func choice<Choice: ParameterChoice>(_ address: ParameterAddress, _ identifier: String, _ name: String, _ type: Choice.Type, default defaultChoice: Choice) -> AUParameter {
        makeParameter(
            identifier: identifier, name: name, address: address.rawValue,
            range: 0...Double(Choice.allCases.count - 1), unit: .indexed, canRamp: false,
            valueStrings: Choice.allCases.map(\.displayName), initialValue: Double(defaultChoice.rawValue)
        )
    }

    private static func toggle(_ address: ParameterAddress, _ identifier: String, _ name: String) -> AUParameter {
        makeParameter(
            identifier: identifier, name: name, address: address.rawValue,
            range: 0...1, unit: .boolean, canRamp: false, valueStrings: nil, initialValue: 0
        )
    }

    private static func makeParameter(
        identifier: String, name: String, address: AUParameterAddress, range: ClosedRange<Double>,
        unit: AudioUnitParameterUnit, canRamp: Bool, valueStrings: [String]?, initialValue: Double
    ) -> AUParameter {
        var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
        if canRamp { flags.insert(.flag_CanRamp) }
        let parameter = AUParameterTree.createParameter(
            withIdentifier: identifier, name: name, address: address,
            min: AUValue(range.lowerBound), max: AUValue(range.upperBound),
            unit: unit, unitName: nil, flags: flags,
            valueStrings: valueStrings, dependentParameters: nil
        )
        parameter.value = AUValue(initialValue)
        return parameter
    }
}
