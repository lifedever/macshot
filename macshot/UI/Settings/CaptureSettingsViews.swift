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
                // Tags are the values the capture reads: 0 = window + copy,
                // 1 = window only, 2 = copy only.
                Picker(L("OCR & QR Capture"), selection: $model.ocrAction) {
                    Text(L("Show window + copy to clipboard")).tag(0)
                    Text(L("Show window only")).tag(1)
                    Text(L("Copy to clipboard only")).tag(2)
                }
            }

            // Two columns of checkboxes rather than a stack of switches. Ten
            // independent on/off settings in one column, plus the scroll
            // capture group, ran the pane past the bottom of the window on a
            // laptop display — and the pane cannot scroll.
            Section(L("Behavior")) {
                checkboxGrid([
                    (L("Play sound on capture"), $model.playSound),
                    (L("Remember last selected tool"), $model.rememberLastTool),
                    (L("Capture mouse cursor in screenshot"), $model.captureCursor),
                    (L("Double-click selection to copy"), $model.doubleClickToCopy),
                    (L("Hide capture instructions"), $model.hideInstructions),
                    (L("Disable shadow outside selection"), $model.disableOutsideShadow),
                    (L("Close editor after copying"), $model.closeEditorAfterCopy),
                ])
            }

            Section(L("Snapping")) {
                checkboxGrid([
                    (L("Show snap alignment guides"), $model.snapGuides),
                    (L("Snap selection edges to image boundaries"), $model.boundarySnap),
                    (L("Haptic feedback when snapping"), $model.snapHaptics),
                    (L("Enhance browser and Electron element snapping"), $model.browserElementSnap),
                ])
            }

            Section {
                checkboxGrid([
                    (L("Auto-scroll (sends synthetic scroll events)"), $model.autoScroll),
                    (L("Detect fixed/sticky headers"), $model.detectFrozenHeaders),
                ])
                Picker(L("Scroll speed"), selection: $model.scrollSpeed) {
                    Text(L("Slow")).tag(1)
                    Text(L("Medium")).tag(2)
                    Text(L("Fast")).tag(3)
                    Text(L("Very fast")).tag(4)
                }
                .disabled(!model.autoScroll)
                LabeledContent(L("Max height")) {
                    HStack(spacing: 6) {
                        TextField("", value: $model.scrollMaxHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $model.scrollMaxHeight, in: 0...100_000, step: 5_000)
                            .labelsHidden()
                        Text(L("px (0 = unlimited)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Scroll Capture"))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func checkboxGrid(_ items: [(String, Binding<Bool>)]) -> some View {
        let half = (items.count + 1) / 2
        return HStack(alignment: .top, spacing: 24) {
            checkboxColumn(Array(items.prefix(half)))
            checkboxColumn(Array(items.dropFirst(half)))
        }
        .padding(.vertical, 2)
    }

    private func checkboxColumn(_ items: [(String, Binding<Bool>)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Toggle(item.0, isOn: item.1)
                    .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(L("Screenshots and recordings both save here, under this name."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
