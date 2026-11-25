import Foundation

enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "MacShot Offline"
    #else
    static let isOffline = false
    static let displayName = "MacShot"
    #endif

    /// Sparkle runs only in a build that carries a feed. `scripts/release.sh` writes `SUFeedURL`
    /// (this fork's own appcast) into the distributed build, which has its own bundle ID.
    /// Local builds from `scripts/build-install.sh` have none and never update themselves:
    /// the upstream feed would replace them with the official app. Gates the updater itself
    /// plus every entry point that would reach it.
    static let softwareUpdatesEnabled: Bool = {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return !(feed ?? "").isEmpty
    }()
}
