import SwiftUI

/// The capture-menu order list.
///
/// Rows sit directly in the enclosing `Form` section, so the form's own card
/// and row separators do the framing. The AppKit list this replaces drew its
/// own bordered, rounded box *inside* that card — a frame within a frame — and
/// its reorder buttons were bezelled `NSButton`s, which macOS tints with the
/// accent colour and turns into two blue chips on every row.
struct MenuOrderList: View {
    @ObservedObject var model: GeneralSettingsModel

    var body: some View {
        ForEach(Array(model.menuOrder.enumerated()), id: \.element) { index, item in
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(item.title)
                Spacer(minLength: 12)
                arrow("chevron.up", enabled: index > 0, help: L("Move up")) {
                    model.moveMenuItem(from: index, to: index - 1)
                }
                arrow("chevron.down", enabled: index < model.menuOrder.count - 1, help: L("Move down")) {
                    model.moveMenuItem(from: index, to: index + 1)
                }
            }
        }
    }

    /// Plain glyphs rather than buttons with a bezel: on a settings row the
    /// control is secondary to the item it reorders, and a row of bezels reads
    /// as the loudest thing on the pane.
    private func arrow(_ symbol: String, enabled: Bool, help: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
        .disabled(!enabled)
        .help(help)
    }
}
