import AppKit
import Foundation

/// Owns only external-display connection policy. Each wallpaper service keeps
/// ownership of its renderer and persisted state; the scheduler only receives
/// scheduler configuration requests from this coordinator.
@MainActor
final class ExternalDisplayConnectionCoordinator: NSObject {
    static let shared = ExternalDisplayConnectionCoordinator()

    private struct PendingDisplay {
        let screenID: String
        let fingerprint: String
        let name: String
    }

    private struct ExternalDisplaySnapshot {
        let screenID: String
        let fingerprint: String
    }

    private let knownDisplayFingerprintsKey = "external_display_known_fingerprints_v1"
    private let legacyRetainedDisplayFingerprintsKey = "external_display_retained_fingerprints_v1"
    private var isStarted = false
    private var previousExternalDisplays: [String: ExternalDisplaySnapshot] = [:]
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingDisplays: [PendingDisplay] = []
    private var isPresentingPrompt = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        migrateLegacyRetainedDisplayFingerprintsIfNeeded()
        previousExternalDisplays = Self.currentExternalDisplaySnapshots()
        markDisplaysAsKnown(previousExternalDisplays.keys)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged() {
        AppLogger.error(.wallpaper, "ExternalDisplay screen parameters changed", metadata: [
            "previousExternalFingerprints": previousExternalDisplays.count,
            "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
        ])
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.processCurrentDisplays()
            }
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processCurrentDisplays() {
        let scheduler = WallpaperSchedulerService.shared
        scheduler.relinkDisplayConfigsForCurrentScreens()

        let current = Self.currentExternalScreensByFingerprint()
        let currentFingerprints = Set(current.keys)
        let previousFingerprints = Set(previousExternalDisplays.keys)
        let connectedFingerprints = currentFingerprints.subtracting(previousFingerprints)

        AppLogger.error(.wallpaper, "ExternalDisplay processed display change", metadata: [
            "currentExternal": currentFingerprints.count,
            "connected": connectedFingerprints.count,
            "known": knownDisplayFingerprints.count,
            "connectedFingerprints": connectedFingerprints.joined(separator: ",")
        ])

        previousExternalDisplays = Self.currentExternalDisplaySnapshots()

        for fingerprint in connectedFingerprints {
            guard let screen = current[fingerprint] else { continue }
            handleConnectedExternalDisplay(screen)
        }
    }

    private func handleConnectedExternalDisplay(_ screen: NSScreen) {
        Task { @MainActor in
            if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
                // A synchronized display has no independent connect decision.
                markDisplayAsKnown(screen.externalConnectionFingerprint)
                WallpaperSchedulerService.shared.synchronizeCurrentGlobalWallpaperToConnectedDisplays()
                return
            }

            if knownDisplayFingerprints.contains(screen.externalConnectionFingerprint) {
                if await restorePreviousDisplayStateIfAvailable(for: screen) {
                    return
                }
                if WallpaperSchedulerService.shared.resolvedDisplayConfig(for: screen).isEnabled,
                   WallpaperSchedulerService.shared.hasSchedulableItems(for: screen.wallpaperScreenIdentifier) {
                    WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
                }
                return
            }

            pendingDisplays.append(PendingDisplay(
                screenID: screen.wallpaperScreenIdentifier,
                fingerprint: screen.externalConnectionFingerprint,
                name: screen.localizedName
            ))
            presentNextPromptIfNeeded()
        }
    }

    private func restorePreviousDisplayStateIfAvailable(for screen: NSScreen) async -> Bool {
        if VideoWallpaperManager.shared.restorePreviousVideoWallpaperIfAvailable(for: screen) {
            return true
        }
        if await WallpaperEngineXBridge.shared.restorePreviousWallpaperIfAvailable(for: screen) {
            return true
        }
        if StaticImageWallpaperOverlayManager.shared.restorePreviousImageIfAvailable(for: screen) {
            return true
        }
        // Fallback: system-native static wallpaper (including video posters).
        return DesktopWallpaperSyncManager.shared.hasPersistedWallpaperForFingerprint(screen.wallpaperScreenFingerprint)
    }

    private func presentNextPromptIfNeeded() {
        guard !isPresentingPrompt, !pendingDisplays.isEmpty else { return }
        isPresentingPrompt = true
        let display = pendingDisplays.removeFirst()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("externalDisplay.connected.title")
        alert.informativeText = String(format: t("externalDisplay.connected.message"), display.name)
        alert.addButton(withTitle: t("externalDisplay.randomAllWallpapers"))
        alert.addButton(withTitle: t("externalDisplay.openSchedulerSettings"))
        alert.addButton(withTitle: t("externalDisplay.openLibraryWithoutAuto"))
        alert.addButton(withTitle: t("externalDisplay.doNotUseAnyWallpaper"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        markDisplayAsKnown(display.fingerprint)

        if let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == display.screenID
                || $0.externalConnectionFingerprint == display.fingerprint
        }) {
            switch response {
            case .alertFirstButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayForRandomAllWallpapers(screen)
            case .alertSecondButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
                openSchedulerSettings()
            case .alertThirdButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
                openLibrary()
            default:
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
            }
        }

        isPresentingPrompt = false
        presentNextPromptIfNeeded()
    }

    private var knownDisplayFingerprints: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: knownDisplayFingerprintsKey) ?? [])
    }

    private func markDisplayAsKnown(_ fingerprint: String) {
        var fingerprints = knownDisplayFingerprints
        guard fingerprints.insert(fingerprint).inserted else { return }
        UserDefaults.standard.set(fingerprints.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func markDisplaysAsKnown(_ fingerprints: Dictionary<String, ExternalDisplaySnapshot>.Keys) {
        var known = knownDisplayFingerprints
        let originalCount = known.count
        known.formUnion(fingerprints)
        guard known.count != originalCount else { return }
        UserDefaults.standard.set(known.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func migrateLegacyRetainedDisplayFingerprintsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: knownDisplayFingerprintsKey) == nil else { return }

        let retained = Set(defaults.stringArray(forKey: legacyRetainedDisplayFingerprintsKey) ?? [])
        guard !retained.isEmpty else { return }
        defaults.set(retained.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func openLibrary() {
        MainNavigationRequestStore.requestLibraryTab()
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openSchedulerSettings() {
        UserDefaults.standard.set(true, forKey: "settings.openSchedulerOnNextAppearance")
        NotificationCenter.default.post(name: .openSchedulerSettings, object: nil)
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showSettingsWindow(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func currentExternalScreensByFingerprint() -> [String: NSScreen] {
        var result: [String: NSScreen] = [:]
        for screen in NSScreen.screens where !screen.isBuiltInDisplay {
            result[screen.externalConnectionFingerprint] = screen
        }
        return result
    }

    private static func currentExternalDisplaySnapshots() -> [String: ExternalDisplaySnapshot] {
        Dictionary(uniqueKeysWithValues: currentExternalScreensByFingerprint().map { fingerprint, screen in
            (
                fingerprint,
                ExternalDisplaySnapshot(
                    screenID: screen.wallpaperScreenIdentifier,
                    fingerprint: fingerprint
                )
            )
        })
    }
}

extension Notification.Name {
    static let openSchedulerSettings = Notification.Name("com.waifux.openSchedulerSettings")
}
