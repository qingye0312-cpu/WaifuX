import Combine
import Foundation

/// Read-only aggregation for surfaces that display task progress. It never owns
/// work or changes queue state; downloads and video optimization remain the
/// single writers for their own tasks.
@MainActor
final class TaskQueueStatusService: ObservableObject {
    enum Category: CaseIterable, Equatable {
        case download
        case loopAnalysis
        case frameInterpolation
        case bake

        var localizationKey: String {
            switch self {
            case .download: return "statusbar.taskQueue.download"
            case .loopAnalysis: return "statusbar.taskQueue.loopAnalysis"
            case .frameInterpolation: return "statusbar.taskQueue.frameInterpolation"
            case .bake: return "statusbar.taskQueue.bake"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let category: Category
        let title: String
        let progress: Double
    }

    static let shared = TaskQueueStatusService()

    @Published private(set) var entries: [Entry] = []

    private var cancellables = Set<AnyCancellable>()

    private init(
        downloadService: DownloadTaskService = .shared,
        optimizationQueue: VideoOptimizationQueueService = .shared,
        bakeService: BakeService = .shared
    ) {
        let bakeServicePublisher = Publishers.CombineLatest3(
            bakeService.$isBaking,
            bakeService.$progress,
            bakeService.$statusText
        )

        Publishers.CombineLatest3(
            downloadService.$tasks,
            optimizationQueue.$items,
            bakeServicePublisher
        )
        .map { downloads, optimizations, bake in
            Self.makeEntries(
                downloads: downloads,
                optimizations: optimizations,
                sceneBakeEntries: SceneOfflineBakeProgressTracker.shared.entries,
                standaloneBakeIsRunning: bake.0,
                standaloneBakeProgress: bake.1,
                standaloneBakeStatus: bake.2
            )
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$entries)

        // Scene bake tracker is not ObservableObject; refresh when its notifications fire.
        NotificationCenter.default.publisher(for: .sceneOfflineBakeProgressDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshFromCurrentSources()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sceneOfflineBakeDidComplete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshFromCurrentSources()
            }
            .store(in: &cancellables)
    }

    var combinedProgress: Double {
        guard !entries.isEmpty else { return 0 }
        return entries.reduce(0) { $0 + $1.progress } / Double(entries.count)
    }

    private func refreshFromCurrentSources() {
        entries = Self.makeEntries(
            downloads: DownloadTaskService.shared.tasks,
            optimizations: VideoOptimizationQueueService.shared.items,
            sceneBakeEntries: SceneOfflineBakeProgressTracker.shared.entries,
            standaloneBakeIsRunning: BakeService.shared.isBaking,
            standaloneBakeProgress: BakeService.shared.progress,
            standaloneBakeStatus: BakeService.shared.statusText
        )
    }

    private static func makeEntries(
        downloads: [DownloadTask],
        optimizations: [FrameInterpolationQueueItem],
        sceneBakeEntries: [SceneOfflineBakeProgressTracker.Entry],
        standaloneBakeIsRunning: Bool,
        standaloneBakeProgress: Double,
        standaloneBakeStatus: String
    ) -> [Entry] {
        let downloadEntries = downloads
            .filter(\.isRunning)
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                Entry(id: $0.id, category: .download, title: $0.title, progress: $0.progress)
            }

        let optimizationEntries = optimizations
            .filter { !$0.isTerminalForCleanup }
            .sorted { $0.addedAt < $1.addedAt }
            .map { item -> Entry in
                let pendingOperation = item.currentOperation
                    ?? item.operations.first { !item.completedOperations.contains($0) }
                let category: Category = pendingOperation == .frameInterpolation
                    ? .frameInterpolation
                    : .loopAnalysis
                return Entry(
                    id: item.id.uuidString,
                    category: category,
                    title: item.title,
                    progress: item.progress
                )
            }

        var bakeEntries: [Entry] = []
        for sceneBake in sceneBakeEntries {
            let title = sceneBake.itemID.flatMap {
                MediaLibraryService.shared.downloadRecord(for: $0)?.item.title
            } ?? LocalizationService.shared.t("statusbar.taskQueue.bakeRunning")
            bakeEntries.append(
                Entry(
                    id: "scene-bake-\(sceneBake.id.uuidString)",
                    category: .bake,
                    title: title,
                    progress: sceneBake.progress
                )
            )
        }

        if standaloneBakeIsRunning {
            let title = standaloneBakeStatus.isEmpty
                ? LocalizationService.shared.t("statusbar.taskQueue.bakeRunning")
                : standaloneBakeStatus
            bakeEntries.append(
                Entry(
                    id: "standalone-bake",
                    category: .bake,
                    title: title,
                    progress: standaloneBakeProgress
                )
            )
        }

        return downloadEntries + optimizationEntries + bakeEntries
    }
}
