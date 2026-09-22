import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The beautify style row: the selected swatch, which opens the full grid in a
/// popover.
///
/// The grid runs to several rows of swatches — inline in a settings row it was
/// clipped to a strip and unusable. This is also how the toolbar presents it,
/// so the two controls now behave the same way.
@available(macOS 13.0, *)
struct BeautifyStyleRow: View {
    @Binding var selectedIndex: Int
    @State private var showingPicker = false
    /// Bumped after a background image is chosen so the swatch redraws from the
    /// newly stored data.
    @State private var revision = 0

    var body: some View {
        LabeledContent(L("Style")) {
            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: BeautifyRenderer.swatchImage(styleIndex: selectedIndex, size: 22))
                        .id(revision)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                BeautifyStyleGrid(selectedIndex: $selectedIndex) {
                    revision += 1
                    showingPicker = false
                }
                .frame(width: GradientPickerView.gridSize.width,
                       height: GradientPickerView.gridSize.height)
            }
        }
    }
}

/// The swatch grid itself, wrapping the existing `GradientPickerView` rather
/// than rebuilding it: it already draws every gradient, the custom-image
/// thumbnail and the wallpaper / choose-file actions.
@available(macOS 13.0, *)
private struct BeautifyStyleGrid: NSViewRepresentable {
    @Binding var selectedIndex: Int
    var onPick: () -> Void

    func makeNSView(context: Context) -> GradientPickerView {
        let picker = GradientPickerView(selectedIndex: selectedIndex)
        picker.onSelect = { index in
            selectedIndex = index
            onPick()
        }
        picker.onCustomImage = {
            guard Self.chooseCustomImage() else { return }
            selectedIndex = -1
            onPick()
        }
        picker.onUseWallpaper = {
            Self.captureWallpaper { captured in
                guard captured else { return }
                selectedIndex = -1
                onPick()
            }
        }
        return picker
    }

    func updateNSView(_ nsView: GradientPickerView, context: Context) {
        guard nsView.selectedIndex != selectedIndex else { return }
        nsView.selectedIndex = selectedIndex
        nsView.needsDisplay = true
    }

    /// Read from the type, not from `nsView.frame`: SwiftUI has already
    /// resized the view by the time it asks, so the frame reports whatever it
    /// proposed — which collapsed the popover to an empty rounded rectangle.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GradientPickerView,
                      context: Context) -> CGSize? {
        GradientPickerView.gridSize
    }

    /// Store a user-picked background image under the key the overlay reads.
    private static func chooseCustomImage() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return false }
        UserDefaults.standard.set(data, forKey: "beautifyCustomBgImageData")
        return true
    }

    private static func captureWallpaper(completion: @escaping (Bool) -> Void) {
        guard #available(macOS 14.0, *), let screen = NSScreen.main else {
            completion(false)
            return
        }
        Task { @MainActor in
            guard let image = await DesktopWallpaper.capture(for: screen),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                completion(false)
                return
            }
            UserDefaults.standard.set(png, forKey: "beautifyCustomBgImageData")
            completion(true)
        }
    }
}
