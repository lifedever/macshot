#if !OFFLINE
import Cocoa

/// Uploads to a GitHub repository via the Contents API, the way people use a
/// repo as an image host.
///
/// Deliberately not the Releases or Gist API: a repo path is stable, browsable,
/// and serves through jsDelivr, which is what makes this useful as a host at
/// all. A token with `contents: write` on a single repo is enough.
final class GitHubUploader {

    static let shared = GitHubUploader()

    // MARK: - Configuration

    struct Config {
        let token: String
        /// "owner/repo", as it appears in the URL.
        let repository: String
        let branch: String
        /// Path inside the repo, e.g. "screenshots/". Empty uploads to the root.
        let pathPrefix: String
        /// How the returned link is built. See `LinkStyle`.
        let linkStyle: LinkStyle
        /// Base for `.custom`, e.g. "https://img.example.com".
        let customDomain: String

        var owner: String { repository.split(separator: "/").first.map(String.init) ?? "" }
        var repo: String { repository.split(separator: "/").dropFirst().first.map(String.init) ?? "" }

        var isValid: Bool {
            !token.isEmpty && !owner.isEmpty && !repo.isEmpty
        }
    }

    enum LinkStyle: String, CaseIterable {
        /// raw.githubusercontent.com — always current, rate-limited, not a CDN.
        case raw
        /// cdn.jsdelivr.net — cached at the edge, the usual choice for a repo
        /// used as an image host.
        case jsdelivr
        /// A domain the user points at the repo themselves.
        case custom
    }

    var config: Config {
        let ud = UserDefaults.standard
        return Config(
            token: ud.string(forKey: "githubToken") ?? "",
            repository: ud.string(forKey: "githubRepository") ?? "",
            branch: ud.string(forKey: "githubBranch") ?? "main",
            pathPrefix: ud.string(forKey: "githubPathPrefix") ?? "",
            linkStyle: LinkStyle(rawValue: ud.string(forKey: "githubLinkStyle") ?? "") ?? .jsdelivr,
            customDomain: ud.string(forKey: "githubCustomDomain") ?? ""
        )
    }

    var isConfigured: Bool { config.isValid }

    /// Progress callback (0.0–1.0), called on the main thread.
    var onProgress: ((Double) -> Void)?

    enum GitHubError: LocalizedError {
        case notConfigured
        case encodingFailed
        case http(Int, String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return L("GitHub upload is not configured — check Settings.")
            case .encodingFailed:
                return L("Could not encode the image.")
            case .http(let code, let message):
                // 401/403 is nearly always the token; saying so beats echoing
                // GitHub's generic "Bad credentials".
                if code == 401 || code == 403 {
                    return L("GitHub rejected the token — check that it has contents write access to the repository.")
                }
                if code == 404 {
                    return L("Repository or branch not found — check the owner/repo and branch name.")
                }
                return "GitHub: \(code) \(message)"
            case .malformedResponse:
                return L("GitHub returned a response macshot could not read.")
            }
        }
    }

    // MARK: - Upload

    func uploadImage(_ image: NSImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = ImageEncoder.encode(image) else {
            completion(.failure(GitHubError.encodingFailed))
            return
        }
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey)
            ?? FilenameFormatter.defaultTemplate
        let filename = "\(FilenameFormatter.format(template: template)).\(ImageEncoder.fileExtension)"
        upload(data: data, filename: filename, completion: completion)
    }

    func uploadVideo(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let data = try Data(contentsOf: url)
            upload(data: data, filename: url.lastPathComponent, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    func upload(data: Data, filename: String, completion: @escaping (Result<String, Error>) -> Void) {
        let config = self.config
        guard config.isValid else {
            completion(.failure(GitHubError.notConfigured))
            return
        }

        let path = Self.joinPath(prefix: config.pathPrefix, filename: filename)
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)/contents/\(encodedPath)")
        else {
            completion(.failure(GitHubError.notConfigured))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("macshot", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "message": "Add \(filename)",
            "content": data.base64EncodedString(),
            "branch": config.branch.isEmpty ? "main" : config.branch,
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(GitHubError.encodingFailed))
            return
        }
        request.httpBody = httpBody

        let task = URLSession.shared.dataTask(with: request) { responseData, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(GitHubError.malformedResponse))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = (responseData
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?
                        .flatMap { $0["message"] as? String }) ?? ""
                    completion(.failure(GitHubError.http(http.statusCode, message)))
                    return
                }
                completion(.success(Self.publicURL(for: path, config: config)))
            }
        }
        // The progress callback exists so the upload toast can show a bar; the
        // Contents API is a single PUT, so it only ever reports start and end.
        onProgress?(0.1)
        task.resume()
    }

    // MARK: - Links

    static func joinPath(prefix: String, filename: String) -> String {
        var cleaned = prefix.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        if !cleaned.isEmpty && !cleaned.hasSuffix("/") { cleaned += "/" }
        return cleaned + filename
    }

    static func publicURL(for path: String, config: Config) -> String {
        let branch = config.branch.isEmpty ? "main" : config.branch
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch config.linkStyle {
        case .raw:
            return "https://raw.githubusercontent.com/\(config.owner)/\(config.repo)/\(branch)/\(encoded)"
        case .jsdelivr:
            return "https://cdn.jsdelivr.net/gh/\(config.owner)/\(config.repo)@\(branch)/\(encoded)"
        case .custom:
            var base = config.customDomain.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            return base.isEmpty ? encoded : "\(base)/\(encoded)"
        }
    }

    /// Verify the token and repository without uploading anything: read the
    /// repo metadata, which the same `contents` scope already allows.
    func testConnection(completion: @escaping (Result<String, Error>) -> Void) {
        let config = self.config
        guard config.isValid,
              let url = URL(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)")
        else {
            completion(.failure(GitHubError.notConfigured))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("macshot", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(GitHubError.malformedResponse))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = (data
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?
                        .flatMap { $0["message"] as? String }) ?? ""
                    completion(.failure(GitHubError.http(http.statusCode, message)))
                    return
                }
                let permissions = (data
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?
                    .flatMap { $0["permissions"] as? [String: Any] })
                let canPush = permissions?["push"] as? Bool ?? false
                completion(.success(canPush
                    ? L("Connected — the token can write to this repository.")
                    : L("Connected, but the token cannot write to this repository.")))
            }
        }.resume()
    }
}
#endif
