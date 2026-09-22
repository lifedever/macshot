#if !OFFLINE
import AppKit
import Combine
import SwiftUI

/// Backing store for the Uploads settings pane.
@MainActor
final class UploadSettingsModel: ObservableObject {

    enum Provider: String, CaseIterable, Identifiable {
        case imgbb
        case gdrive
        case s3
        case github

        var id: String { rawValue }

        var title: String {
            switch self {
            case .imgbb:  return L("imgbb (images only)")
            case .gdrive: return L("Google Drive (images + videos)")
            case .s3:     return L("S3-Compatible (images + videos)")
            case .github: return L("GitHub repository (images + videos)")
            }
        }
    }

    @Published var provider: Provider {
        didSet { store(provider.rawValue, "uploadProvider", oldValue.rawValue) }
    }

    @Published var confirmBeforeUpload: Bool {
        didSet { store(confirmBeforeUpload, "uploadConfirmEnabled", oldValue) }
    }

    // MARK: imgbb

    @Published var imgbbKey: String {
        didSet { store(imgbbKey, "imgbbAPIKey", oldValue) }
    }

    // MARK: Google Drive

    @Published var gdriveFolder: String {
        didSet { store(gdriveFolder, "gdriveFolderName", oldValue) }
    }

    @Published var gdriveSignedIn: Bool = GoogleDriveUploader.shared.isSignedIn

    /// Sign-in and sign-out are the same button in the UI, and the uploader
    /// already models them as one toggle.
    func toggleGoogleDrive() {
        if GoogleDriveUploader.shared.isSignedIn {
            GoogleDriveUploader.shared.signOut()
            gdriveSignedIn = false
            return
        }
        GoogleDriveUploader.shared.signIn(from: NSApp.keyWindow) { [weak self] _ in
            self?.gdriveSignedIn = GoogleDriveUploader.shared.isSignedIn
            GoogleDriveUploader.shared.fetchUserEmail { }
        }
    }

    // MARK: S3

    @Published var s3Endpoint: String    { didSet { store(s3Endpoint, "s3Endpoint", oldValue) } }
    @Published var s3Region: String      { didSet { store(s3Region, "s3Region", oldValue) } }
    @Published var s3Bucket: String      { didSet { store(s3Bucket, "s3Bucket", oldValue) } }
    @Published var s3AccessKey: String   { didSet { store(s3AccessKey, "s3AccessKeyID", oldValue) } }
    @Published var s3SecretKey: String   { didSet { store(s3SecretKey, "s3SecretAccessKey", oldValue) } }
    @Published var s3PublicURL: String   { didSet { store(s3PublicURL, "s3PublicURLBase", oldValue) } }
    @Published var s3PathPrefix: String  { didSet { store(s3PathPrefix, "s3PathPrefix", oldValue) } }
    @Published var s3PublicRead: Bool    { didSet { store(s3PublicRead, "s3PublicRead", oldValue) } }

    // MARK: GitHub

    @Published var githubToken: String       { didSet { store(githubToken, "githubToken", oldValue) } }
    @Published var githubRepository: String  { didSet { store(githubRepository, "githubRepository", oldValue) } }
    @Published var githubBranch: String      { didSet { store(githubBranch, "githubBranch", oldValue) } }
    @Published var githubPathPrefix: String  { didSet { store(githubPathPrefix, "githubPathPrefix", oldValue) } }
    @Published var githubLinkStyle: GitHubUploader.LinkStyle {
        didSet { store(githubLinkStyle.rawValue, "githubLinkStyle", oldValue.rawValue) }
    }
    @Published var githubCustomDomain: String { didSet { store(githubCustomDomain, "githubCustomDomain", oldValue) } }

    /// Result of the last "Test Connection", shown inline under the button.
    @Published var githubTestResult: String?
    @Published var githubTestFailed = false

    /// What a link will look like with the current settings, so the choice of
    /// link style and path prefix is concrete before the first upload.
    var githubSampleLink: String {
        let path = GitHubUploader.joinPath(prefix: githubPathPrefix, filename: "screenshot.png")
        return GitHubUploader.publicURL(for: path, config: GitHubUploader.shared.config)
    }

    func testGitHub() {
        githubTestResult = L("Checking…")
        githubTestFailed = false
        GitHubUploader.shared.testConnection { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.githubTestResult = message
                self.githubTestFailed = false
            case .failure(let error):
                self.githubTestResult = error.localizedDescription
                self.githubTestFailed = true
            }
        }
    }

    // MARK: Lifecycle

    init() {
        let ud = UserDefaults.standard
        provider = Provider(rawValue: ud.string(forKey: "uploadProvider") ?? "") ?? .imgbb
        confirmBeforeUpload = ud.bool(forKey: "uploadConfirmEnabled")
        imgbbKey = ud.string(forKey: "imgbbAPIKey") ?? ""
        gdriveFolder = ud.string(forKey: "gdriveFolderName") ?? "macshot"
        s3Endpoint = ud.string(forKey: "s3Endpoint") ?? ""
        s3Region = ud.string(forKey: "s3Region") ?? "auto"
        s3Bucket = ud.string(forKey: "s3Bucket") ?? ""
        s3AccessKey = ud.string(forKey: "s3AccessKeyID") ?? ""
        s3SecretKey = ud.string(forKey: "s3SecretAccessKey") ?? ""
        s3PublicURL = ud.string(forKey: "s3PublicURLBase") ?? ""
        s3PathPrefix = ud.string(forKey: "s3PathPrefix") ?? ""
        s3PublicRead = ud.bool(forKey: "s3PublicRead")
        githubToken = ud.string(forKey: "githubToken") ?? ""
        githubRepository = ud.string(forKey: "githubRepository") ?? ""
        githubBranch = ud.string(forKey: "githubBranch") ?? "main"
        githubPathPrefix = ud.string(forKey: "githubPathPrefix") ?? ""
        githubLinkStyle = GitHubUploader.LinkStyle(rawValue: ud.string(forKey: "githubLinkStyle") ?? "") ?? .jsdelivr
        githubCustomDomain = ud.string(forKey: "githubCustomDomain") ?? ""
    }

    private func store<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
#endif
