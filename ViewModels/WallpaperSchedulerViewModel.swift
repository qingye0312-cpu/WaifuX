import Foundation
import Combine
import AppKit

@MainActor
class WallpaperSchedulerViewModel: ObservableObject {
    @Published var config: SchedulerConfig = .default
    @Published var isRunning: Bool = false

    private let schedulerService = WallpaperSchedulerService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        schedulerService.$config
            .receive(on: DispatchQueue.main)
            .assign(to: &$config)

        schedulerService.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)
    }

    // MARK: - Control Actions

    func toggleScheduler() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        schedulerService.start()
    }

    func stop() {
        schedulerService.stop()
    }

    func updateInterval(_ minutes: Int) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: minutes,
                order: config.order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs,
                isGlobalDisplaySyncEnabled: config.isGlobalDisplaySyncEnabled,
                globalDisplayConfig: config.globalDisplayConfig
            )
        )
    }

    func updateOrder(_ order: ScheduleOrder) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs,
                isGlobalDisplaySyncEnabled: config.isGlobalDisplaySyncEnabled,
                globalDisplayConfig: config.globalDisplayConfig
            )
        )
    }

    func updateIncludeWallpapers(_ include: Bool) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: config.order,
                includeWallpapers: include,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs,
                isGlobalDisplaySyncEnabled: config.isGlobalDisplaySyncEnabled,
                globalDisplayConfig: config.globalDisplayConfig
            )
        )
    }

    func updateIncludeMedia(_ include: Bool) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: config.order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: include,
                displayConfigs: config.displayConfigs,
                isGlobalDisplaySyncEnabled: config.isGlobalDisplaySyncEnabled,
                globalDisplayConfig: config.globalDisplayConfig
            )
        )
    }

    // MARK: - Per-Display Config

    func displayConfig(for screenID: String) -> DisplaySchedulerConfig {
        config.resolvedDisplayConfig(for: screenID)
    }

    func displayConfig(for screen: NSScreen) -> DisplaySchedulerConfig {
        schedulerService.resolvedDisplayConfig(for: screen)
    }

    /// 返回写入配置时使用的 screenID；必要时先把旧 NSScreenNumber 下的配置迁移过来。
    func displayConfigScreenID(for screen: NSScreen) -> String {
        schedulerService.displayConfigScreenID(for: screen)
    }

    func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
        schedulerService.updateDisplayEnabled(enabled, for: screenID)
    }

    func updateDisplayInterval(_ minutes: Int, for screenID: String) {
        schedulerService.updateDisplayInterval(minutes, for: screenID)
    }

    func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
        schedulerService.updateDisplayOrder(order, for: screenID)
    }

    func updateDisplayIncludeWallpapers(_ include: Bool, for screenID: String) {
        schedulerService.updateDisplayIncludeWallpapers(include, for: screenID)
    }

    func updateDisplayIncludeMedia(_ include: Bool, for screenID: String) {
        schedulerService.updateDisplayIncludeMedia(include, for: screenID)
    }

    func updateDisplayFolderIDs(_ folderIDs: [String]?, for screenID: String) {
        schedulerService.updateDisplayFolderIDs(folderIDs, for: screenID)
    }

    func updateDisplayWebSceneSwitchSeconds(_ seconds: Int?, for screenID: String) {
        schedulerService.updateDisplayWebSceneSwitchSeconds(seconds, for: screenID)
    }

    // MARK: - Global Display Sync

    var isGlobalDisplaySyncEnabled: Bool {
        config.isGlobalDisplaySyncEnabled
    }

    var globalDisplayConfig: DisplaySchedulerConfig {
        config.globalDisplayConfig
    }

    func updateGlobalDisplaySyncEnabled(_ enabled: Bool) {
        schedulerService.updateGlobalDisplaySyncEnabled(enabled)
    }

    func updateGlobalDisplayEnabled(_ enabled: Bool) {
        schedulerService.updateGlobalDisplayEnabled(enabled)
    }

    func updateGlobalDisplayInterval(_ minutes: Int) {
        schedulerService.updateGlobalDisplayInterval(minutes)
    }

    func updateGlobalDisplayOrder(_ order: ScheduleOrder) {
        schedulerService.updateGlobalDisplayOrder(order)
    }

    func updateGlobalDisplayIncludeWallpapers(_ include: Bool) {
        schedulerService.updateGlobalDisplayIncludeWallpapers(include)
    }

    func updateGlobalDisplayIncludeMedia(_ include: Bool) {
        schedulerService.updateGlobalDisplayIncludeMedia(include)
    }

    func updateGlobalDisplayFolderIDs(_ folderIDs: [String]?) {
        schedulerService.updateGlobalDisplayFolderIDs(folderIDs)
    }

    func updateGlobalDisplayWebSceneSwitchSeconds(_ seconds: Int?) {
        schedulerService.updateGlobalDisplayWebSceneSwitchSeconds(seconds)
    }

    // MARK: - Computed Properties

    var intervalLabel: String {
        intervalLabel(for: config.intervalMinutes)
    }

    func intervalLabel(for minutes: Int) -> String {
        if minutes == SchedulerConfig.intervalOnEndMinutes {
            return "Play to End"
        }
        if minutes == SchedulerConfig.intervalOnUnlockMinutes {
            return "Change on Unlock"
        }
        switch minutes {
        case 1: return "1 min"
        case 3: return "3 min"
        case 5: return "5 min"
        case 15: return "15 min"
        case 30: return "30 min"
        case 60: return "1 hour"
        case 360: return "6 hours"
        case 1440: return "24 hours"
        default: return "\(minutes) min"
        }
    }

    var orderLabel: String {
        switch config.order {
        case .sequential: return "Sequential"
        case .random: return "Random"
        }
    }
}
