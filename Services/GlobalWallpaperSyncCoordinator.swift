import AppKit
import Foundation

/// Serializes global wallpaper application and retains one durable rollback
/// target. The coordinator owns transaction ordering; renderer/player services
/// retain ownership of their own process and playback state.
@MainActor
final class GlobalWallpaperSyncCoordinator {
    static let shared = GlobalWallpaperSyncCoordinator()

    struct Snapshot: Codable, Equatable {
        let localPath: String
        let muted: Bool
        let fallbackPosterPath: String?
        let sceneBakeItemID: String?
        let bakedVideoPath: String?
        let requirePlaybackEndSupport: Bool
        let reason: String

        private enum CodingKeys: String, CodingKey {
            case localPath
            case muted
            case fallbackPosterPath
            case sceneBakeItemID
            case bakedVideoPath
            case requirePlaybackEndSupport
            case reason
        }

        init(
            localPath: String,
            muted: Bool,
            fallbackPosterPath: String?,
            sceneBakeItemID: String?,
            bakedVideoPath: String?,
            requirePlaybackEndSupport: Bool,
            reason: String
        ) {
            self.localPath = localPath
            self.muted = muted
            self.fallbackPosterPath = fallbackPosterPath
            self.sceneBakeItemID = sceneBakeItemID
            self.bakedVideoPath = bakedVideoPath
            self.requirePlaybackEndSupport = requirePlaybackEndSupport
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localPath = try container.decode(String.self, forKey: .localPath)
            muted = try container.decode(Bool.self, forKey: .muted)
            fallbackPosterPath = try container.decodeIfPresent(String.self, forKey: .fallbackPosterPath)
            sceneBakeItemID = try container.decodeIfPresent(String.self, forKey: .sceneBakeItemID)
            bakedVideoPath = try container.decodeIfPresent(String.self, forKey: .bakedVideoPath)
            // Older durable snapshots omitted this flag; default keeps reapply permissive.
            requirePlaybackEndSupport = try container.decodeIfPresent(
                Bool.self,
                forKey: .requirePlaybackEndSupport
            ) ?? false
            reason = try container.decode(String.self, forKey: .reason)
        }

        var localURL: URL {
            URL(fileURLWithPath: localPath)
        }

        func options(isGlobalTransaction: Bool) -> LocalWallpaperApplyService.Options {
            LocalWallpaperApplyService.Options(
                animatedTransition: false,
                requirePlaybackEndSupport: requirePlaybackEndSupport,
                muted: muted,
                fallbackPosterURL: fallbackPosterPath.map(URL.init(fileURLWithPath:)),
                // 与调度器/手动设壁纸一致：无 HD poster 时后台抽帧补系统静帧
                generatePosterFromVideoIfNeeded: true,
                sceneBakeItemID: sceneBakeItemID,
                bakedVideoPath: bakedVideoPath,
                isGlobalTransaction: isGlobalTransaction,
                // Global applies target every connected screen; share one decoder.
                usesSharedVideoDecoder: true,
                reason: reason
            )
        }
    }

    private struct PendingRequest {
        let snapshot: Snapshot
        let animatedTransition: Bool
        let continuation: CheckedContinuation<Bool, Error>
    }

    private enum TransactionError: LocalizedError {
        case applicationReturnedFalse
        case noConnectedDisplays
        case rollbackFailed(original: Error, rollback: Error)

        var errorDescription: String? {
            switch self {
            case .applicationReturnedFalse:
                return "全局壁纸应用未完成"
            case .noConnectedDisplays:
                return "当前没有可用的显示器"
            case .rollbackFailed(let original, let rollback):
                return "全局壁纸应用失败：\(original.localizedDescription)；回滚也失败：\(rollback.localizedDescription)"
            }
        }
    }

    private static let stateKey = "global_wallpaper_sync_last_success_v1"
    private var lastSuccessfulSnapshot: Snapshot?
    private var pendingRequests: [PendingRequest] = []
    private var activeTask: Task<Void, Never>?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              FileManager.default.fileExists(atPath: snapshot.localPath) else {
            return
        }
        lastSuccessfulSnapshot = snapshot
    }

    /// Last successful global apply. Exposed for diagnostics and regressions.
    var lastSuccessfulApply: Snapshot? {
        lastSuccessfulSnapshot
    }

    func apply(
        localURL: URL,
        options: LocalWallpaperApplyService.Options
    ) async throws -> Bool {
        let snapshot = Snapshot(
            localPath: localURL.standardizedFileURL.path,
            muted: options.muted,
            fallbackPosterPath: options.fallbackPosterURL?.standardizedFileURL.path,
            sceneBakeItemID: options.sceneBakeItemID,
            bakedVideoPath: options.bakedVideoPath,
            requirePlaybackEndSupport: options.requirePlaybackEndSupport,
            reason: options.reason
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(
                snapshot: snapshot,
                animatedTransition: options.animatedTransition,
                continuation: continuation
            ))
            startNextRequestIfNeeded()
        }
    }

    /// Called when the user turns global sync on while wallpapers may already
    /// differ per display. Prefer the durable last success; otherwise capture
    /// the primary screen's live wallpaper, including bake metadata when known.
    func synchronizeCurrentWallpaperAfterEnabling() {
        if let lastSuccessfulSnapshot,
           FileManager.default.fileExists(atPath: lastSuccessfulSnapshot.localPath) {
            Task {
                _ = try? await apply(
                    localURL: lastSuccessfulSnapshot.localURL,
                    options: lastSuccessfulSnapshot.options(isGlobalTransaction: false)
                )
            }
            return
        }

        guard let snapshot = currentWallpaperSnapshot(reason: "globalSyncEnable") else {
            return
        }
        Task {
            _ = try? await apply(
                localURL: snapshot.localURL,
                options: snapshot.options(isGlobalTransaction: false)
            )
        }
    }

    /// Re-broadcast the last successful global wallpaper to the current screen
    /// set after a display is connected (or the set otherwise grows).
    func reapplyToConnectedDisplays() {
        guard !NSScreen.screens.isEmpty else { return }

        if let lastSuccessfulSnapshot,
           FileManager.default.fileExists(atPath: lastSuccessfulSnapshot.localPath) {
            Task {
                _ = try? await apply(
                    localURL: lastSuccessfulSnapshot.localURL,
                    options: lastSuccessfulSnapshot.options(isGlobalTransaction: false)
                )
            }
            return
        }

        synchronizeCurrentWallpaperAfterEnabling()
    }

    /// 全局同步关闭时停止接受旧的排队事务，并等待当前事务完整收尾。
    /// 当前事务不能直接半途杀掉，否则可能只改完部分显示器；等待结束后再由各屏调度覆盖。
    func drainBeforeLeavingGlobalMode() async {
        let abandoned = pendingRequests
        pendingRequests.removeAll()
        for request in abandoned {
            request.continuation.resume(throwing: CancellationError())
        }

        if let activeTask {
            await activeTask.value
        }
    }

    private func startNextRequestIfNeeded() {
        guard activeTask == nil, !pendingRequests.isEmpty else { return }
        let request = pendingRequests.removeFirst()
        activeTask = Task { [weak self] in
            guard let self else {
                request.continuation.resume(throwing: CancellationError())
                return
            }

            do {
                let applied = try await self.perform(request)
                request.continuation.resume(returning: applied)
            } catch {
                request.continuation.resume(throwing: error)
            }

            self.activeTask = nil
            self.startNextRequestIfNeeded()
        }
    }

    private func perform(_ request: PendingRequest) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: request.snapshot.localPath) else {
            throw LocalWallpaperApplyService.ApplyError.missingFile(request.snapshot.localPath)
        }

        let targetScreens = NSScreen.screens
        guard !targetScreens.isEmpty else {
            throw TransactionError.noConnectedDisplays
        }

        let rollbackSnapshot = lastSuccessfulSnapshot ?? currentWallpaperSnapshot(reason: "globalRollback")
        var options = request.snapshot.options(isGlobalTransaction: true)
        options.animatedTransition = request.animatedTransition

        do {
            let applied = try await LocalWallpaperApplyService.apply(
                localURL: request.snapshot.localURL,
                targetScreens: targetScreens,
                options: options
            )
            guard applied else { throw TransactionError.applicationReturnedFalse }
            lastSuccessfulSnapshot = request.snapshot
            persistLastSuccessfulSnapshot()
            return true
        } catch {
            guard let rollbackSnapshot,
                  rollbackSnapshot.localPath != request.snapshot.localPath,
                  FileManager.default.fileExists(atPath: rollbackSnapshot.localPath) else {
                throw error
            }
            do {
                _ = try await LocalWallpaperApplyService.apply(
                    localURL: rollbackSnapshot.localURL,
                    targetScreens: NSScreen.screens,
                    options: rollbackSnapshot.options(isGlobalTransaction: true)
                )
                throw error
            } catch let rollbackError {
                if rollbackError.localizedDescription == error.localizedDescription {
                    throw error
                }
                throw TransactionError.rollbackFailed(original: error, rollback: rollbackError)
            }
        }
    }

    private func currentWallpaperSnapshot(reason: String) -> Snapshot? {
        guard let primary = NSScreen.screens.first,
              let currentURL = CurrentWallpaperService.shared.activeURL(for: primary.wallpaperScreenIdentifier),
              currentURL.isFileURL,
              FileManager.default.fileExists(atPath: currentURL.path) else {
            return nil
        }

        let standardized = currentURL.standardizedFileURL
        let enriched = enrichSnapshotMetadata(for: standardized)

        return Snapshot(
            localPath: standardized.path,
            muted: VideoWallpaperManager.shared.isMuted,
            fallbackPosterPath: enriched.fallbackPosterPath,
            sceneBakeItemID: enriched.sceneBakeItemID,
            bakedVideoPath: enriched.bakedVideoPath,
            requirePlaybackEndSupport: false,
            reason: reason
        )
    }

    /// When the live active path is a Workshop directory or baked companion,
    /// carry bake metadata so re-enable / reconnect can prefer the same
    /// baked video path the scheduler would have used.
    private func enrichSnapshotMetadata(for localURL: URL) -> (
        fallbackPosterPath: String?,
        sceneBakeItemID: String?,
        bakedVideoPath: String?
    ) {
        var fallbackPosterPath: String?
        var sceneBakeItemID: String?
        var bakedVideoPath: String?

        if let primary = NSScreen.screens.first,
           let poster = VideoWallpaperManager.shared.posterURL(for: primary),
           poster.isFileURL {
            fallbackPosterPath = poster.standardizedFileURL.path
        }

        let path = localURL.path
        if let record = MediaLibraryService.shared.downloadedItems.first(where: { item in
            let candidate = item.localFileURL.standardizedFileURL.path
            return candidate == path
                || path.hasPrefix(candidate + "/")
                || candidate.hasPrefix(path + "/")
        }), let art = SceneOfflineBakeService.usableArtifact(from: record) {
            sceneBakeItemID = record.item.id
            if SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                bakedVideoPath = art.videoPath
            }
        }

        return (fallbackPosterPath, sceneBakeItemID, bakedVideoPath)
    }

    private func persistLastSuccessfulSnapshot() {
        guard let lastSuccessfulSnapshot,
              let data = try? JSONEncoder().encode(lastSuccessfulSnapshot) else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}
