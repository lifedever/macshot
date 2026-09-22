import SwiftUI

/// The About pane.
///
/// Not a `Form`: this is an identity card, not a list of settings. It also
/// carries the attribution that used to live in a footer strip under every
/// pane — the About tab is where macOS apps put it.
struct AboutSettingsView: View {
    var onCopyDiagnostics: () -> Void
    var onExport: () -> Void
    var onImport: () -> Void
    var onRevealSettingsFile: () -> Void

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return String(format: L("Version %@ (%@)"), short, build)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.bottom, 12)

            Text(BuildVariant.displayName)
                .font(.system(size: 22, weight: .bold))
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            Text(L("A free, open-source screenshot & screen recording tool for macOS.\nFully native — built with Swift and AppKit."))
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            #if OFFLINE
            Text(L("Offline build: upload and cloud storage integrations are removed. Update checks may still connect to MacShot's update server. Screenshots and recordings stay local unless you share or save them yourself."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            #endif

            Text(L("Licensed under GPLv3"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)

            Button(L("Copy Screen Info"), action: onCopyDiagnostics)
                .padding(.top, 18)
            Text(L("Copies display and capture diagnostics to the clipboard"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Divider()
                .padding(.vertical, 18)

            // Settings transfer lives here rather than under General: it is
            // about the app's own files, like everything else on this pane, and
            // General had no room left for it.
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Settings Backup"))
                    .font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(L("Export Settings…"), action: onExport)
                    Button(L("Import Settings…"), action: onImport)
                    Spacer()
                    Button(L("Reveal Settings File in Finder"), action: onRevealSettingsFile)
                        .controlSize(.small)
                }
                Text(L("Export your preferences to a file to move them to another Mac or a clean install. Upload credentials, your save folder, and screenshot history are not included. Settings are stored inside macshot's app container."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 18)

            HStack {
                Text("\(L("Made by")) sw33tLie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("github.com/sw33tLie/macshot",
                     destination: URL(string: "https://github.com/sw33tLie/macshot")!)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }
}
