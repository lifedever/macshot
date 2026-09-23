#if !OFFLINE
import AppKit
import SwiftUI

/// The Uploads settings pane.
///
/// Only the selected provider's fields are shown. The AppKit pane stacked all
/// of them — Drive, S3 and imgbb at once — which ran well past a screen and
/// made it hard to tell which credentials were actually in use.
struct UploadSettingsView: View {
    @StateObject private var model = UploadSettingsModel()

    var body: some View {
        Form {
            Section {
                Picker(L("Provider"), selection: $model.provider) {
                    ForEach(UploadSettingsModel.Provider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Toggle(L("Ask before uploading"), isOn: $model.confirmBeforeUpload)
            }

            switch model.provider {
            case .imgbb:   imgbbSection
            case .gdrive:  googleDriveSection
            case .s3:      s3Section
            case .github:  githubSection
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private var imgbbSection: some View {
        Section {
            TextField(L("API key"), text: $model.imgbbKey)
        } header: {
            Text("imgbb")
        } footer: {
            Text(L("A shared key is included — get your own free key at imgbb.com/api if you hit rate limits. Images only (no video support)."))
        }
        let uploads = model.imgbbUploads
        if !uploads.isEmpty {
            Section(L("Upload History")) {
                ForEach(uploads) { upload in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button(L("Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(upload.link, forType: .string)
                            }
                            Button(L("Delete")) {
                                if let url = URL(string: upload.deleteURL) { NSWorkspace.shared.open(url) }
                            }
                            .disabled(URL(string: upload.deleteURL) == nil)
                            .help(upload.deleteURL)
                        }
                    } label: {
                        Text(upload.link)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var googleDriveSection: some View {
        Section(L("Google Drive")) {
            LabeledContent(L("Account")) {
                HStack(spacing: 8) {
                    Text(model.gdriveSignedIn ? L("Signed in") : L("Not signed in"))
                        .foregroundStyle(.secondary)
                    Button(model.gdriveSignedIn ? L("Sign Out") : L("Sign In with Google")) {
                        model.toggleGoogleDrive()
                    }
                }
            }
            TextField(L("Folder"), text: $model.gdriveFolder)
        }
    }

    private var s3Section: some View {
        Section(L("S3-Compatible Storage")) {
            field(L("Endpoint"), $model.s3Endpoint, placeholder: "https://abc.r2.cloudflarestorage.com")
            field(L("Region"), $model.s3Region, placeholder: "auto")
            field(L("Bucket"), $model.s3Bucket)
            field(L("Access Key"), $model.s3AccessKey)
            SecureField(L("Secret Key"), text: $model.s3SecretKey)
            field(L("Public URL"), $model.s3PublicURL, placeholder: "https://cdn.example.com")
            field(L("Path Prefix"), $model.s3PathPrefix, placeholder: "screenshots/")
            Toggle(L("Make uploads publicly readable"), isOn: $model.s3PublicRead)
            LabeledContent(L("Connection")) {
                Button(L("Test Connection")) { model.testS3() }
            }
            if let result = model.s3TestResult {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(model.s3TestFailed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var githubSection: some View {
        Section {
            SecureField(L("Token"), text: $model.githubToken, prompt: Text("ghp_…"))
            field(L("Repository"), $model.githubRepository, placeholder: "owner/repo")
            field(L("Branch"), $model.githubBranch, placeholder: "main")
            field(L("Path Prefix"), $model.githubPathPrefix, placeholder: "screenshots/")
            Picker(L("Link style"), selection: $model.githubLinkStyle) {
                Text("jsDelivr CDN").tag(GitHubUploader.LinkStyle.jsdelivr)
                Text("raw.githubusercontent.com").tag(GitHubUploader.LinkStyle.raw)
                Text(L("Custom domain")).tag(GitHubUploader.LinkStyle.custom)
            }
            if model.githubLinkStyle == .custom {
                field(L("Domain"), $model.githubCustomDomain, placeholder: "https://img.example.com")
            }
            LabeledContent {
                Text(model.githubSampleLink)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } label: {
                Text(L("Example link")).foregroundStyle(.secondary)
            }
            LabeledContent(L("Connection")) {
                Button(L("Test Connection")) { model.testGitHub() }
            }
            // The result gets its own row: beside the button it wrapped into
            // the trailing column and collided with it.
            if let result = model.githubTestResult {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(model.githubTestFailed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L("GitHub repository"))
        } footer: {
            Text(L("Create a fine-grained token with Contents write access to this one repository. The repository must be public for the links to be readable without a token."))
        }
    }

    /// A text row. Written as a bare `TextField` rather than a `LabeledContent`
    /// wrapping one: the form styles its own text rows — bordered field on the
    /// trailing edge, prompt aligned with the value — and wrapping it throws all
    /// of that away, leaving an invisible, unlabelled field.
    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        TextField(label, text: text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
    }
}
#endif
