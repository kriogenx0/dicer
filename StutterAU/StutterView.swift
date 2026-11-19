import SwiftUI
import VoltaNative

struct StutterView: View {
    let viewModel: StutterViewModel

    private var rateMode: RateMode { viewModel.choice(RateMode.self, at: .rateMode) }
    private var tempoSource: TempoSource { viewModel.choice(TempoSource.self, at: .tempoSource) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Morbid: Stutter")
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.disabled)

            // Controls for the mode that isn't in use stay visible but disabled,
            // so switching modes never moves anything.
            HStack(spacing: 16) {
                choicePicker("Rate", RateMode.self, at: .rateMode)
                    .frame(width: 150)
                choicePicker("Note Length", SpeedDivision.self, at: .speed)
                    .disabled(rateMode != .sync)
            }
            choicePicker("Tempo", TempoSource.self, at: .tempoSource)
                .frame(width: 160)

            HStack(spacing: 16) {
                VoltaKnob("Rate", spec: .rate, value: binding(.rate), disabledText: "Synced")
                    .disabled(rateMode != .free)
                VoltaKnob("BPM", spec: .bpm, value: binding(.bpm), disabledText: "Host")
                    .disabled(tempoSource != .set)
                VoltaKnob("Gate", spec: .gate, value: binding(.gate))
                VoltaKnob("Mix", spec: .mix, value: binding(.mix))
                VoltaKnob("Pitch", spec: .pitch, value: binding(.pitch))
                triggerButton
            }
            .frame(maxWidth: .infinity)

            choicePicker("Pattern Length", PatternLength.self, at: .patternLength)

            StepGridView(viewModel: viewModel)
        }
        .padding()
        .frame(minWidth: 620, minHeight: 460)
        .background(Color.voltaCanvas)
        .voltaControls()
    }

    /// Latching: stays on, firing the stutter on every step, until clicked again.
    private var triggerButton: some View {
        Toggle(isOn: Binding(
            get: { viewModel.value(.trigger) >= 0.5 },
            set: { viewModel.setValue($0 ? 1 : 0, for: .trigger) }
        )) {
            Text("Trigger")
                .frame(width: 56, height: 32)
        }
        .toggleStyle(TriggerToggleStyle())
        .help("Stutter on every step until turned off")
        .accessibilityHint("Stutters on every step, ignoring the pattern, while on")
    }

    private func choicePicker<Choice: ParameterChoice>(_ label: String, _ type: Choice.Type, at address: ParameterAddress) -> some View {
        Picker(label, selection: Binding(
            get: { viewModel.choice(type, at: address).rawValue },
            set: { viewModel.setValue(Double($0), for: address) }
        )) {
            ForEach(Choice.allCases, id: \.rawValue) { option in
                Text(option.displayName).tag(option.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    private func binding(_ address: ParameterAddress) -> Binding<Double> {
        Binding(get: { viewModel.value(address) }, set: { viewModel.setValue($0, for: address) })
    }
}

private struct StepGridView: View {
    let viewModel: StutterViewModel

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: PatternLength.stepsPerBar)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<viewModel.activeStepCount, id: \.self) { index in
                StepCell(isOn: viewModel.stepStates[index]) {
                    viewModel.toggleStep(index)
                }
            }
        }
    }
}

/// Latching Trigger: a quiet bordered button while off, the accent-filled primary action while on.
private struct TriggerToggleStyle: ToggleStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let button = Button { configuration.isOn.toggle() } label: { configuration.label }
        if configuration.isOn {
            button.buttonStyle(.voltaProminent).selectedTrait(true)
        } else {
            button.buttonStyle(.volta).selectedTrait(false)
        }
    }
}

private extension View {
    func selectedTrait(_ isOn: Bool) -> some View {
        accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct StepCell: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.voltaAccent) private var accent

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: VoltaTokens.radiusCheckbox)
                .fill(isOn ? accent : Color.secondary.opacity(VoltaTokens.opacityControlFillHover))
                .frame(height: 28)
                .animation(VoltaDesign.animation, value: isOn)
        }
        .buttonStyle(.voltaHover)
    }
}
