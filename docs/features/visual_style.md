# Visual style

Dicer's Stutter view and the Morbid host app use the shared Perfect Ink look from [kriogenx0/volta-native](https://github.com/kriogenx0/volta-native), the same quiet style as FireMail: system font, hairline borders, faint 150 ms hovers, and one ember accent. It follows macOS light and dark mode through system colours.

## What uses it

- **Knobs:** `VoltaKnob` (drag up or down, Option for fine, scroll, arrow keys, double-click to reset, click the value to type one). Each knob reads its range, default and format from a `KnobSpec` preset in `StutterAU/ParameterSpec.swift` (`.rate`, `.bpm`, `.gate`, `.mix`, `.pitch`). The parameter tree reads the same presets.
- **Trigger:** a quiet bordered button while off, the accent-filled primary action while latched on (`TriggerToggleStyle` in `StutterView.swift`).
- **Step grid:** steps that are on show the accent, steps that are off show a faint fill, and hovering a step outlines it.
- **Host app:** Play is the primary action. The toolbar uses `.voltaControls()` and a `VoltaDivider`.
- The rate, note length, tempo and pattern pickers are still system segmented controls.

## Dependencies

`project.yml` adds the `VoltaNative` Swift package (branch `main`) to both `StutterAU` and `MorbidHost`, because the host compiles the StutterAU sources too. Run `make generate` after pulling to regenerate the project.

## Tests

There are no Dicer tests for this. `KnobSpec` logic is unit tested in volta-native (`KnobSpecTests`).

## History

- Implemented 2026-11-19: the knob and `KnobSpec` moved from this repo into volta-native, and the Stutter view was restyled. Not deployed. It has not been built or tried in a host yet, because it was written in a Linux session with no Xcode.
