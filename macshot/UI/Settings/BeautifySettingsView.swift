import SwiftUI

/// The Beautify pane: the background, framing and shadow applied to a capture.
///
/// Its own pane rather than a group under Output — with the full parameter set
/// it ran Output past a screen, and it is a feature of its own, not one of the
/// choices about where a file goes.
@available(macOS 13.0, *)
struct BeautifySettingsView: View {
    @ObservedObject var model: CaptureSettingsModel

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).frame(width: 180)
                Text(unit.isEmpty ? "\(Int(value.wrappedValue))" : "\(Int(value.wrappedValue)) \(unit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("Beautify captures"), isOn: $model.beautifyEnabled)

                // Everything the toolbar's beautify row offers, so the settings
                // and the toolbar are the same feature rather than an on/off
                // switch here and the real controls somewhere else.
                Group {
                    BeautifyStyleRow(selectedIndex: $model.beautifyStyleIndex)
                    Picker(L("Frame"), selection: $model.beautifyMode) {
                        Text(L("Window chrome")).tag(0)
                        Text(L("Rounded corners")).tag(1)
                    }
                    slider(L("Padding"), $model.beautifyPadding, model.beautifyPaddingRange, unit: "pt")
                    slider(L("Corner radius"), $model.beautifyCornerRadius, 0...30, unit: "pt")
                    slider(L("Shadow"), $model.beautifyShadowRadius, 0...100, unit: "")
                    // Blurring a gradient does nothing, so it only appears for
                    // image backgrounds.
                    if model.beautifyUsesImageBackground {
                        slider(L("Background blur"), $model.beautifyBackgroundBlur, 0...50, unit: "")
                    }
                }
                .disabled(!model.beautifyEnabled)
            } header: {
                Text(L("Beautify"))
            } footer: {
                Text(L("Places the capture on a background with rounded corners and a drop shadow."))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
