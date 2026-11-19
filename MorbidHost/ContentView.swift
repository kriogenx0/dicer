import SwiftUI

struct ContentView: View {
    @State private var engineController = AudioEngineController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(engineController.isPlaying ? "Stop" : "Play") {
                    if engineController.isPlaying {
                        engineController.stop()
                    } else {
                        engineController.play()
                    }
                }
                .disabled(!engineController.isReady)

                Stepper(value: bpmBinding, in: 40...240, step: 1) {
                    Text("BPM: \(Int(engineController.bpm))")
                }
                .frame(width: 160)

                Spacer()

                Text(engineController.statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding()

            Divider()

            if let viewModel = engineController.stutterViewModel {
                StutterView(viewModel: viewModel)
            } else {
                ProgressView("Loading effect view…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 660, minHeight: 560)
        .onAppear {
            engineController.start()
        }
    }

    private var bpmBinding: Binding<Double> {
        Binding(
            get: { engineController.bpm },
            set: { engineController.bpm = $0 }
        )
    }
}
