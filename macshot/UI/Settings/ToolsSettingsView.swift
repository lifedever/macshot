import SwiftUI

/// The Tools pane: which annotation tools and toolbar actions are shown.
///
/// The three lists are behind a segmented picker rather than stacked. Stacked,
/// they ran to about forty checkboxes in one column; only one of them is ever
/// being edited at a time, and the picker names what each list belongs to more
/// clearly than a heading above a grid did.
struct ToolsSettingsView: View {
    @StateObject private var model = ToolsSettingsModel()

    var body: some View {
        Form {
            Section {
                Picker("", selection: $model.group) {
                    ForEach(ToolsSettingsModel.Group.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                // Two columns: this many toggles in a single column is a scroll
                // even on a tall display.
                let items = model.items
                let half = (items.count + 1) / 2
                HStack(alignment: .top, spacing: 24) {
                    column(items: Array(items.prefix(half)))
                    column(items: Array(items.dropFirst(half)))
                }
                .padding(.vertical, 2)
            } header: {
                Text(model.group.title)
            } footer: {
                Text(model.group.footnote)
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
