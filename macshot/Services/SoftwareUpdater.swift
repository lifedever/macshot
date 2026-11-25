import AppKit
import Combine
import os
import Sparkle
import UserNotifications

/// Sparkle, announced quietly. A scheduled check that finds an update posts a system
/// notification instead of opening Sparkle's window; clicking it opens Settings › General,
/// whose Update button brings up Sparkle's update window (the release notes and Install).
/// Choosing Install downloads, installs and relaunches without a second confirmation.
///
/// Off in builds without a feed (`BuildVariant.softwareUpdatesEnabled`): `start()` does
/// nothing there, and the Settings rows that read this object are hidden.
final class SoftwareUpdater: NSObject, ObservableObject {
    static let shared = SoftwareUpdater()

    /// The update a check found and the user has not dealt with yet, for the Settings row.
    @Published private(set) var availableVersion: String?

    /// Opens Settings on the pane that holds the Update button. Set by the app delegate.
    var openUpdateSettings: (() -> Void)?

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    nonisolated private static let notificationID = "software-update"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "macshot", category: "updates")

    var isRunning: Bool { updater != nil }

    func start() {
        guard BuildVariant.softwareUpdatesEnabled, updater == nil else { return }
        let driver = MacShotUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            Self.log.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Updates only ever install from the update window, so a quit that installs one can't
        // pass for a crash.
        updater.automaticallyDownloadsUpdates = false
        UNUserNotificationCenter.current().delegate = self
        self.userDriver = driver
        self.updater = updater
    }

    /// Settings' Update / Check for Updates button and the menu's Check for Updates. Brings up
    /// the update a scheduled check is holding, or checks now.
    func checkForUpdates() {
        guard let updater else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    private func announce(_ version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard granted else {
                        // Notifications are off: show the update window rather than let the
                        // update go unnoticed.
                        self.checkForUpdates()
                        return
                    }
                    let content = UNMutableNotificationContent()
                    content.title = String(format: L("Version %@ is available"), version)
                    content.body = L("Click to update in Settings.")
                    content.userInfo = ["version": version]
                    center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
                }
            }
        }
    }

    private func withdrawAnnouncement() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}

// MARK: - SPUUpdaterDelegate

/// No `allowedChannels(for:)`: this fork publishes no beta channel, so only the default
/// channel is read, whatever an imported upstream `betaUpdatesEnabled` says.
extension SoftwareUpdater: SPUUpdaterDelegate {
    /// Each release ships one DMG per architecture, each with its own feed beside the
    /// `SUFeedURL` one (`appcast.xml` → `appcast-arm64.xml` / `appcast-x86_64.xml`).
    /// `SUFeedURL` itself lists both and is what builds without this method read.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return Self.architectureFeedURL(base: base, architecture: Self.hardwareArchitecture)
    }

    /// `…/appcast.xml` → `…/appcast-<architecture>.xml`; nil for a feed not named `.xml`.
    static func architectureFeedURL(base: String, architecture: String) -> String? {
        guard base.hasSuffix(".xml") else { return nil }
        return String(base.dropLast(4)) + "-" + architecture + ".xml"
    }

    /// The Mac's architecture, not the build's: an Intel build running under Rosetta reads the
    /// Apple silicon feed, so its next update installs the native build.
    static let hardwareArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "arm64"
        }
        return "x86_64"
        #endif
    }()
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

extension SoftwareUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never for a scheduled check: the notification announces it instead. User-initiated
    /// checks don't come through here; Sparkle always shows those.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            availableVersion = version
            if !handleShowingUpdate { announce(version) }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { withdrawAnnouncement() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
            withdrawAnnouncement()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension SoftwareUpdater: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let version = request.content.userInfo["version"] as? String
        if request.identifier == Self.notificationID {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // After a relaunch Sparkle no longer holds the update; the notification
                    // still names it, and the Update button checks again.
                    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    if self.availableVersion == nil, let version, version != current {
                        self.availableVersion = version
                    }
                    self.openUpdateSettings?()
                }
            }
        }
        completionHandler()
    }

    /// Show the banner even while macshot is the active app (Settings or an editor open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// Sparkle's standard windows, with two changes:
/// - no stop between download and install: after Install in the update window, the update
///   installs and the app relaunches without asking again;
/// - "no update" on the latest (or a newer, locally installed) version is a short alert of our
///   own — Sparkle's named the app, repeated the version and added the build number.
final class MacShotUserDriver: SPUStandardUserDriver {
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        DispatchQueue.main.async { reply(.install) }
    }

    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        let upToDate = reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            || reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue
        guard upToDate else {
            // An OS too old or too new, or no Apple silicon: Sparkle explains those.
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let alert = NSAlert()
        alert.messageText = L("You're up to date")
        alert.informativeText = String(format: L("Current version: %@"), version)
        alert.addButton(withTitle: L("OK"))
        // Run the modal loop from the run loop, not from inside whatever main-queue block
        // Sparkle called us from: a modal there holds up every other main-queue job.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                acknowledgement()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
