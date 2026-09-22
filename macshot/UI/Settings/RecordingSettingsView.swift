import SwiftUI

/// The Recording settings pane.
struct RecordingSettingsView: View {
    @StateObject private var model = RecordingSettingsModel()

    var body: some View {
        Form {
            // Where a recording lands and what it is called now come from the
            // save folder and filename template under Output — recordings had
            // their own pair, so the setting you edited was not necessarily
            // the one that applied.
            Section(L("Output")) {
                Picker(L("Frame rate"), selection: $model.frameRate) {
                    ForEach(RecordingSettingsModel.frameRates, id: \.self) { fps in
                        Text(String(format: L("%d fps"), fps)).tag(fps)
                    }
                }
            }

            Section(L("Behavior")) {
                Picker(L("When done"), selection: $model.onStop) {
                    Text(L("Open editor")).tag("editor")
                    Text(L("Show in Finder")).tag("finder")
                    Text(L("Copy to clipboard")).tag("clipboard")
                }
                Toggle(isOn: $model.hideHUD) {
                    Text(L("Hide recording controls"))
                    Text(L("Stop recording from the menu bar icon instead."))
                }
            }

            Section(L("Webcam")) {
                Picker(L("Position"), selection: $model.webcamPosition) {
                    Text(L("Bottom Right")).tag("bottomRight")
                    Text(L("Bottom Left")).tag("bottomLeft")
                    Text(L("Top Right")).tag("topRight")
                    Text(L("Top Left")).tag("topLeft")
                }
                LabeledContent(L("Size")) {
                    HStack(spacing: 8) {
                        Slider(value: $model.webcamSize, in: model.webcamSizeRange)
                            .frame(width: 200)
                        Text("\(Int(model.webcamSize)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker(L("Shape"), selection: $model.webcamShape) {
                    Text(L("Circle")).tag("circle")
                    Text(L("Rounded Rectangle")).tag("roundedRect")
                }
            }

        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
