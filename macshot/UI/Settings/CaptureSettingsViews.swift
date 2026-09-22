import SwiftUI

/// Capture behaviour: what a capture does, and how the selection snaps.
///
/// Split out of the old 36-control Capture tab, which was four unrelated
/// sections deep and could not fit a screen at any window height.
struct CaptureSettingsView: View {
    @ObservedObject var model: CaptureSettingsModel

    var body: some View {
        Form {
            Section(L("Capture")) {
                Picker(L("Enter / Quick Capture"), selection: $model.quickCaptureMode) {
                    Text(L("Save to file")).tag(0)
                    Text(L("Copy to clipboard")).tag(1)
                    Text(L("Save + copy to clipboard")).tag(2)
                    Text(L("Do nothing")).tag(3)
                }
                Toggle(L("Also open in Editor"), isOn: $model.quickCaptureOpenEditor)
                Toggle(L("Close editor after copying"), isOn: $model.closeEditorAfterCopy)
                Picker(L("OCR & QR Capture"), selection: $model.ocrAction) {
                    Text(L("Show results window")).tag(0)
                    Text(L("Copy to clipboard")).tag(1)
                }
            }

            Section(L("Behavior")) {
                Toggle(L("Play sound on capture"), isOn: $model.playSound)
                Toggle(L("Remember last selected tool"), isOn: $model.rememberLastTool)
                Toggle(L("Capture mouse cursor in screenshot"), isOn: $model.captureCursor)
                Toggle(L("Double-click selection to copy"), isOn: $model.doubleClickToCopy)
                Toggle(L("Hide capture instructions"), isOn: $model.hideInstructions)
                Toggle(L("Disable shadow outside selection"), isOn: $model.disableOutsideShadow)
            }

            Section(L("Snapping")) {
                Toggle(L("Show snap alignment guides"), isOn: $model.snapGuides)
                Toggle(L("Snap selection edges to image boundaries"), isOn: $model.boundarySnap)
                Toggle(L("Haptic feedback when snapping"), isOn: $model.snapHaptics)
                Toggle(L("Enhance browser and Electron element snapping"), isOn: $model.browserElementSnap)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// The floating preview that appears after a capture.
struct ThumbnailSettingsView: View {
    @ObservedObject var model: CaptureSettingsModel

    var body: some View {
        Form {
            Section(L("Floating Preview")) {
                Toggle(L("Show floating thumbnail after capture"), isOn: $model.showThumbnail)
                Picker(L("Dismiss after"), selection: $model.thumbnailAutoDismiss) {
                    Text(L("Never")).tag(0)
                    Text(L("3 seconds")).tag(3)
                    Text(L("5 seconds")).tag(5)
                    Text(L("10 seconds")).tag(10)
                    Text(L("30 seconds")).tag(30)
                }
                Picker(L("Multiple previews"), selection: $model.thumbnailStacking) {
                    Text(L("Stack (keep all)")).tag(0)
                    Text(L("Replace (show only latest)")).tag(1)
                }
                Picker(L("Position"), selection: $model.thumbnailCorner) {
                    Text(L("Bottom Right")).tag(0)
                    Text(L("Bottom Left")).tag(1)
                    Text(L("Top Right")).tag(2)
                    Text(L("Top Left")).tag(3)
                }
                LabeledContent(L("Preview size")) {
                    HStack(spacing: 8) {
                        Slider(value: $model.thumbnailScale, in: 0.5...2.0)
                            .frame(width: 200)
                        Text(String(format: "%.0f%%", model.thumbnailScale * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle(L("Fit image in preview (letterbox)"), isOn: $model.thumbnailLetterbox)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Where captures go: save behaviour, file format, and history.
struct OutputSettingsView: View {
    @ObservedObject var model: CaptureSettingsModel

    var body: some View {
        Form {
            Section(L("Saving")) {
                Picker(L("Save action"), selection: $model.saveAction) {
                    ForEach(SaveActionPreference.allCases, id: \.rawValue) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                LabeledContent(L("Save folder")) {
                    HStack(spacing: 8) {
                        Text(model.saveFolderPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button(L("Browse…")) { model.browseSaveFolder() }
                    }
                }
                LabeledContent(L("Filename")) {
                    HStack(spacing: 8) {
                        TextField("", text: $model.filenameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 200)
                        Button(L("Reset")) { model.resetFilenameTemplate() }
                    }
                }
                LabeledContent {
                    Text(model.filenamePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                } label: {
                    Text(L("Preview")).foregroundStyle(.secondary)
                }
            }

            Section(L("Image")) {
                Picker(L("Image format"), selection: $model.imageFormat) {
                    ForEach(model.availableFormats, id: \.rawValue) { format in
                        Text(format.rawValue.uppercased()).tag(format.rawValue)
                    }
                }
                // PNG and HEIC ignore the quality value, so the slider is only
                // shown for the formats it actually affects.
                if model.formatHasQuality {
                    LabeledContent(L("Quality")) {
                        HStack(spacing: 8) {
                            Slider(value: $model.imageQuality, in: 0.1...1.0)
                                .frame(width: 200)
                            Text(String(format: "%.0f%%", model.imageQuality * 100))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Toggle(L("Save at standard resolution (1x)"), isOn: $model.downscaleRetina)
            }

            Section(L("History")) {
                Toggle(L("Unlimited"), isOn: $model.historyUnlimited)
                if !model.historyUnlimited {
                    LabeledContent(L("History size")) {
                        HStack(spacing: 6) {
                            TextField("", value: $model.historySize, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $model.historySize, in: 0...9999)
                                .labelsHidden()
                        }
                    }
                }
                Toggle(L("Order history by last edit"), isOn: $model.historyOrderByLastEdit)
            }

            Section(L("Translation")) {
                Picker(L("Engine"), selection: $model.useAppleTranslation) {
                    Text(L("Apple")).tag(true)
                    Text(L("Google")).tag(false)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
