enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "MacShot Offline"
    #else
    static let isOffline = false
    static let displayName = "MacShot"
    #endif

    /// Sparkle is off in this fork — see the comment on the removed `SUFeedURL` in Info.plist.
    /// The upstream feed serves the official build, so an update would overwrite this
    /// locally-built app. Rebuild with `scripts/build-install.sh` to update instead.
    /// Gates the updater itself plus every entry point that would reach it.
    static let softwareUpdatesEnabled = false
}
