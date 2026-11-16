import SwiftUI

/// The Tools pane: which annotation tools and toolbar actions are shown.
///
/// The three lists are behind a segmented picker rather than stacked. Stacked,
/// they ran to about forty checkboxes in one column; only one of them is ever
/// being edited at a time, and the picker names what each list belongs to more
/// clearly than a heading above a grid did.
struct ToolsSettingsView: View {
    @StateObject private var model = ToolsSettingsModel()
    /// Only for the translation engine, which belongs to the Translate tool.
    @ObservedObject var captureModel: CaptureSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.hideBottomToolbar) {
                    Text(L("Hide the bottom toolbar"))
                    Text(L("Pick tools with their keyboard shortcuts instead."))
                }
                Toggle(L("Start captures in move mode"), isOn: $model.startCapturesInMoveMode)
                Picker("", selection: $model.group) {
                    ForEach(ToolsSettingsModel.Group.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                if model.group == .colors {
                    PresetColorGrid(model: model)
                    HStack {
                        Button(L("Add Color")) { model.addPresetColor() }
                            .disabled(!model.canAddPresetColor)
                        Spacer()
                        Button(L("Reset to default")) { model.resetPresetColors() }
                    }
                } else {
                    // Two columns: this many toggles in a single column is a
                    // scroll even on a tall display.
                    let items = model.items
                    let half = (items.count + 1) / 2
                    HStack(alignment: .top, spacing: 24) {
                        column(items: Array(items.prefix(half)))
                        column(items: Array(items.dropFirst(half)))
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(model.group.title)
            } footer: {
                Text(model.group.footnote)
            }

            // The Translate tool's engine. It sat under Output next to the
            // image format, which described the file a capture writes — this
            // describes what one of the tools above does.
            Section(L("Translation")) {
                Picker(L("Engine"), selection: $captureModel.useAppleTranslation) {
                    Text(L("Apple")).tag(true)
                    Text(L("Google")).tag(false)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func column(items: [ToolsSettingsModel.Item]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                Toggle(item.label, isOn: Binding(
                    get: { model.isEnabled(item) },
                    set: { model.setEnabled($0, for: item) }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The colour picker's preset swatches as editable wells, six to a row like
/// the picker itself, each with a button that removes it.
private struct PresetColorGrid: View {
    @ObservedObject var model: ToolsSettingsModel
    private static let perRow = 6

    var body: some View {
        if model.presetColors.isEmpty {
            Text(L("No default colors."))
                .foregroundStyle(.secondary)
        } else {
            let columns = Array(repeating: GridItem(.fixed(64), spacing: 12, alignment: .leading), count: Self.perRow)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(model.presetColors.enumerated()), id: \.offset) { index, color in
                    HStack(spacing: 2) {
                        ColorPicker("", selection: Binding(
                            get: { color },
                            set: { model.setPresetColor($0, at: index) }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Button {
                            model.removePresetColor(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete"))
                        .accessibilityLabel(L("Delete"))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
