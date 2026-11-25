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
    /// (this fork's own appcast) into every build it makes — releases and local installs from
    /// `scripts/build-install.sh` alike, whose build number is the commit count. A plain Xcode
    /// build has no feed and stays out of updates. Gates the updater itself plus every entry
    /// point that would reach it.
    static let softwareUpdatesEnabled: Bool = {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return !(feed ?? "").isEmpty
    }()
}
