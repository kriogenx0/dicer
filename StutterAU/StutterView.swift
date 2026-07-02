import SwiftUI

struct StutterView: View {
    let viewModel: StutterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Morbid: Stutter").font(.headline)

            Picker("Speed", selection: speedBinding) {
                ForEach(SpeedDivision.allCases, id: \.rawValue) { division in
                    Text(division.displayName).tag(division.rawValue)
                }
            }
            .pickerStyle(.segmented)

            sliderRow(label: "Gate", value: gateBinding, range: 0...100, valueText: String(format: "%.0f%%", viewModel.gatePercent))
            sliderRow(label: "Mix", value: mixBinding, range: 0...1, valueText: String(format: "%.0f%%", viewModel.mix * 100))
            sliderRow(label: "Pitch", value: pitchBinding, range: -24...24, valueText: String(format: "%+.0f st", viewModel.pitchSemitones))

            Picker("Pattern Length", selection: patternLengthBinding) {
                ForEach(PatternLength.allCases, id: \.rawValue) { length in
                    Text(length.displayName).tag(length.rawValue)
                }
            }
            .pickerStyle(.segmented)

            StepGridView(viewModel: viewModel)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 380)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
            Slider(value: value, in: range)
            Text(valueText).frame(width: 56, alignment: .trailing).monospacedDigit()
        }
    }

    private var speedBinding: Binding<Int> {
        Binding(get: { viewModel.speedIndex }, set: { viewModel.setSpeedIndex($0) })
    }
    private var gateBinding: Binding<Double> {
        Binding(get: { viewModel.gatePercent }, set: { viewModel.setGatePercent($0) })
    }
    private var mixBinding: Binding<Double> {
        Binding(get: { viewModel.mix }, set: { viewModel.setMix($0) })
    }
    private var pitchBinding: Binding<Double> {
        Binding(get: { viewModel.pitchSemitones }, set: { viewModel.setPitchSemitones($0) })
    }
    private var patternLengthBinding: Binding<Int> {
        Binding(get: { viewModel.patternLengthIndex }, set: { viewModel.setPatternLengthIndex($0) })
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

private struct StepCell: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isOn ? Color.accentColor : Color.gray.opacity(0.25))
                .frame(height: 28)
        }
        .buttonStyle(.plain)
    }
}
