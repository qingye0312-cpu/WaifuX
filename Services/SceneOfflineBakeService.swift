import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Kingfisher

enum SceneOfflineBakeError: LocalizedError {
    case cliNotFound
    case webCliNotFound
    case ineligible
    case contentRootMissing
    case insufficientMemory
    case concurrentBakeInProgress
    case bakeProcessFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 wallpaper-wgpu"
        case .webCliNotFound: return "未找到 wallpaperengine-cli"
        case .ineligible: return "当前 Scene 不适合离线烘焙（资格不足）"
        case .contentRootMissing: return "内容目录不存在，请重新下载"
        case .insufficientMemory: return LocalizationService.shared.t("sceneBake.error.insufficientMemory.bake")
        case .concurrentBakeInProgress: return LocalizationService.shared.t("sceneBake.error.concurrent")
        case .bakeProcessFailed(let msg): return msg
        }
    }
}

enum SceneBakeRenderer: String, CaseIterable, Codable, Hashable, Sendable {
    case wallpaperWgpu
    case wallpaperEngineWeb

    var displayName: String {
        switch self {
        case .wallpaperWgpu: return "1. wallpaper-wgpu"
        case .wallpaperEngineWeb: return "2. wallpaperengine-cli Web"
        }
    }
}

extension Notification.Name {
    /// Scene 离线烘焙完成（成功或失败）。`object` 为 `SceneBakeArtifact?`，失败时为 `nil`。
    static let sceneOfflineBakeDidComplete = Notification.Name("sceneOfflineBakeDidComplete")
    /// 烘焙视频抽帧封面已生成。`object` 为 `String`（itemID），`userInfo["thumbnailURL"]` 为 `URL`。
    static let sceneOfflineBakeThumbnailDidUpdate = Notification.Name("sceneOfflineBakeThumbnailDidUpdate")
    /// 烘焙进度更新。`object` 为 `String`（itemID），`userInfo["progress"]` 为 `Double`（0.0 ~ 1.0）。
    static let sceneOfflineBakeProgressDidUpdate = Notification.Name("sceneOfflineBakeProgressDidUpdate")
}

@discardableResult
@MainActor
func regenerateSceneBakePosterAndNotify(itemID: String, videoURL: URL) async -> URL? {
    guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) else { return nil }

    // 重新烘焙时 MP4 路径通常不变（analysisId+分辨率+fps+时长）；必须先清列表帧，
    // 否则 library 优先 list_*.jpg 会一直显示旧画面。
    VideoThumbnailCache.shared.removeListThumbnail(forLocalVideo: videoURL)

    // 并行重生：高清 poster（锁屏/桌面/详情）+ 列表完整画幅小图（我的库网格）
    async let posterTask = VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
        forLocalVideo: videoURL,
        itemID: itemID,
        forceRegenerate: true
    )
    async let listTask = VideoThumbnailCache.shared.regenerateListThumbnailJPEGFileURL(forLocalVideo: videoURL)
    let posterURL = await posterTask
    let listURL = await listTask

    // 库列表优先完整画幅 list 帧；无则退 poster
    let displayURL = listURL ?? posterURL
    guard let displayURL else { return nil }

    let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
    for url in [displayURL, posterURL, listURL].compactMap({ $0 }) {
        try? await ImageCache.default.removeImage(forKey: url.cacheKey)
        try? await ImageCache.default.removeImage(
            forKey: url.cacheKey,
            processorIdentifier: processor.identifier
        )
    }
    print("[BakeService] ✅ 已刷新烘焙封面 item=\(itemID) list=\(listURL?.lastPathComponent ?? "nil") poster=\(posterURL?.lastPathComponent ?? "nil")")

    NotificationCenter.default.post(
        name: .sceneOfflineBakeThumbnailDidUpdate,
        object: itemID,
        userInfo: ["thumbnailURL": displayURL]
    )
    return displayURL
}

/// Enough information to rebuild an unfinished Scene/Web bake after relaunch.
struct PersistentOfflineBakeJob: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Hashable, Sendable {
        case scene
        case web
    }

    let id: UUID
    let key: String
    let kind: Kind
    let itemID: String?
    let recordID: String?
    let contentRootPath: String
    let eligibility: SceneBakeEligibilitySnapshot?
    let cacheItemID: String?
    let durationSeconds: Double
    let fps: Int
    let renderer: SceneBakeRenderer
    let persistArtifactToItemID: String?
    let progressItemID: String?
    let addedAt: Date

    static func scene(
        id: UUID = UUID(),
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        renderer: SceneBakeRenderer,
        persistArtifactToItemID: String?,
        progressItemID: String?
    ) -> PersistentOfflineBakeJob {
        let normalizedRoot = contentRoot.standardizedFileURL.path
        let key = [
            Kind.scene.rawValue,
            normalizedRoot,
            eligibility.analysisId.uuidString,
            cacheItemID,
            renderer.rawValue,
            String(fps),
            String(format: "%.3f", durationSeconds),
        ].joined(separator: "|")
        return PersistentOfflineBakeJob(
            id: id,
            key: key,
            kind: .scene,
            itemID: progressItemID ?? persistArtifactToItemID,
            recordID: persistArtifactToItemID,
            contentRootPath: normalizedRoot,
            eligibility: eligibility,
            cacheItemID: cacheItemID,
            durationSeconds: durationSeconds,
            fps: Int(fps),
            renderer: renderer,
            persistArtifactToItemID: persistArtifactToItemID,
            progressItemID: progressItemID,
            addedAt: .now
        )
    }

    static func web(
        id: UUID = UUID(),
        record: MediaDownloadRecord,
        contentRoot: URL,
        outputURL: URL,
        durationSeconds: Double,
        fps: Int32
    ) -> PersistentOfflineBakeJob {
        PersistentOfflineBakeJob(
            id: id,
            key: "\(Kind.web.rawValue)|\(outputURL.standardizedFileURL.path)",
            kind: .web,
            itemID: record.item.id,
            recordID: record.id,
            contentRootPath: contentRoot.standardizedFileURL.path,
            eligibility: nil,
            cacheItemID: record.id,
            durationSeconds: durationSeconds,
            fps: Int(fps),
            renderer: .wallpaperEngineWeb,
            persistArtifactToItemID: record.id,
            progressItemID: record.item.id,
            addedAt: .now
        )
    }
}

private struct OfflineBakeQueueCheckpointStore {
    private struct Snapshot: Codable {
        let version: Int
        let jobs: [PersistentOfflineBakeJob]
    }

    static let shared = OfflineBakeQueueCheckpointStore()

    private var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("SceneBake", isDirectory: true)
            .appendingPathComponent("pending-queue.json")
    }

    func load() -> [PersistentOfflineBakeJob] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return []
        }
        var seen = Set<String>()
        return snapshot.jobs
            .sorted { $0.addedAt < $1.addedAt }
            .filter { seen.insert($0.key).inserted }
    }

    func save(_ jobs: [PersistentOfflineBakeJob]) {
        guard !jobs.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(Snapshot(version: 1, jobs: jobs))
                .write(to: fileURL, options: .atomic)
        } catch {
            print("[OfflineBakeQueue] checkpoint write failed: \(error.localizedDescription)")
        }
    }
}

/// 所有离线烘焙共用的串行 FIFO 队列。
///
/// Scene / Web 烘焙都会占用大量 GPU、内存和编码资源。这里允许用户连续提交任务，
/// 但始终只放行一个实际子进程，避免重叠渲染导致内存成倍上涨。
actor OfflineBakeSerialQueue {
    static let shared = OfflineBakeSerialQueue()

    private struct Waiter {
        let jobID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeJobID: UUID?
    private var waiters: [Waiter] = []

    func waitForTurn(jobID: UUID) async {
        if activeJobID == nil, waiters.isEmpty {
            activeJobID = jobID
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(jobID: jobID, continuation: continuation))
        }
    }

    func leave(jobID: UUID) {
        guard activeJobID == jobID else { return }
        activeJobID = nil

        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        activeJobID = next.jobID
        next.continuation.resume()
    }
}

/// 跨详情页生命周期保留的烘焙进度。
/// 详情页关闭后 `@State` 会丢，重进时需要从这里恢复 UI。
@MainActor
final class SceneOfflineBakeProgressTracker {
    static let shared = SceneOfflineBakeProgressTracker()

    enum State: Equatable {
        case queued
        case running
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let itemID: String?
        let persistentJob: PersistentOfflineBakeJob?
        var state: State
        var progress: Double
    }

    struct EnqueueResult {
        let jobID: UUID
        let shouldExecute: Bool
    }

    private(set) var entries: [Entry]
    private var claimedRestoredJobIDs = Set<UUID>()

    private init() {
        let restoredJobs = OfflineBakeQueueCheckpointStore.shared.load()
        entries = restoredJobs.map {
            Entry(
                id: $0.id,
                itemID: $0.itemID,
                persistentJob: $0,
                state: .queued,
                progress: 0
            )
        }
        guard !restoredJobs.isEmpty else { return }
        print("[OfflineBakeQueue] restored \(restoredJobs.count) unfinished bake job(s)")
        Task { @MainActor in
            // MediaLibraryService finishes its own persisted-record load during app startup.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await SceneOfflineBakeService.resumePersistedBakeQueue()
        }
    }

    var activeItemID: String? {
        entries.first(where: { $0.state == .running })?.itemID
    }

    var progress: Double {
        entries.first(where: { $0.state == .running })?.progress ?? 0
    }

    var isBaking: Bool { !entries.isEmpty }

    func enqueue(
        job: PersistentOfflineBakeJob,
        resumingJobID: UUID? = nil
    ) -> EnqueueResult {
        if let resumingJobID,
           let existing = entries.first(where: { $0.id == resumingJobID }) {
            let claimed = claimedRestoredJobIDs.insert(resumingJobID).inserted
            return EnqueueResult(jobID: existing.id, shouldExecute: claimed)
        }
        if let existing = entries.first(where: { $0.persistentJob?.key == job.key }) {
            print("[OfflineBakeQueue] duplicate bake excluded: \(job.key)")
            return EnqueueResult(jobID: existing.id, shouldExecute: false)
        }

        entries.append(
            Entry(
                id: job.id,
                itemID: job.itemID,
                persistentJob: job,
                state: .queued,
                progress: 0
            )
        )
        persistPendingJobs()
        notifyProgress(itemID: job.itemID, progress: 0)
        return EnqueueResult(jobID: job.id, shouldExecute: true)
    }

    func begin(jobID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        entries[index].state = .running
        notifyProgress(itemID: entries[index].itemID, progress: entries[index].progress)
    }

    func update(jobID: UUID, progress value: Double) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        let clamped = min(max(value, 0.0), 0.99)
        entries[index].progress = max(entries[index].progress, clamped)
        notifyProgress(itemID: entries[index].itemID, progress: entries[index].progress)
    }

    func finish(jobID: UUID, success: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        let entry = entries[index]
        if success {
            notifyProgress(itemID: entry.itemID, progress: 1)
        }
        entries.remove(at: index)
        claimedRestoredJobIDs.remove(jobID)
        persistPendingJobs()
    }

    func progress(for itemID: String) -> Double? {
        entries.first(where: { $0.itemID == itemID })?.progress
    }

    var pendingPersistentJobs: [PersistentOfflineBakeJob] {
        entries.compactMap(\.persistentJob).sorted { $0.addedAt < $1.addedAt }
    }

    func discardPersistedJob(id: UUID, reason: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let itemID = entries[index].itemID
        entries.remove(at: index)
        claimedRestoredJobIDs.remove(id)
        persistPendingJobs()
        notifyProgress(itemID: itemID, progress: 0)
        print("[OfflineBakeQueue] dropped restored job \(id): \(reason)")
    }

    private func persistPendingJobs() {
        OfflineBakeQueueCheckpointStore.shared.save(entries.compactMap(\.persistentJob))
    }

    private func notifyProgress(itemID: String?, progress: Double) {
        guard let itemID else { return }
        NotificationCenter.default.post(
            name: .sceneOfflineBakeProgressDidUpdate,
            object: itemID,
            userInfo: ["progress": progress]
        )
    }
}

@MainActor
private final class ScenePreviewProcessController {
    static let shared = ScenePreviewProcessController()
    private var process: Process?
    private var renderer: SceneBakeRenderer?

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        self.process = nil
        self.renderer = nil
    }

    func launch(executableURL: URL, arguments: [String], renderer: SceneBakeRenderer) throws {
        stop()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = SceneOfflineBakeService.rendererLaunchEnvironment(for: executableURL)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.process?.processIdentifier == process.processIdentifier {
                    self.process = nil
                    self.renderer = nil
                }
            }
        }
        try process.run()
        self.process = process
        self.renderer = renderer
    }
}

/// 将 Workshop Scene 预渲染为循环 MP4，并写入下载记录。
enum SceneOfflineBakeService {
    private struct BakedVideoInspection {
        let duration: TimeInterval
        let width: Int
        let height: Int
    }

    /// 已连接显示器中的最高刷新率，用作离线烘焙输出的帧率上限。
    private static var maximumBakeFPS: Double {
        Double(NSScreen.screens.map(\.maxRefreshRate).max() ?? 60)
    }

    /// 将显式请求或用户偏好规范为烘焙器可用的帧率。
    ///
    /// 统一在服务层限制，确保自动烘焙和旧版保存的偏好也不会超过显示器最高刷新率。
    private static func resolvedBakeFPS(requestedFPS: Int32?) -> Int32 {
        let selectedFPS: Double
        if let requestedFPS {
            selectedFPS = Double(requestedFPS)
        } else {
            let savedFPS = UserDefaults.standard.double(forKey: "scene_bake_fps")
            selectedFPS = savedFPS >= 15 ? savedFPS : 30
        }
        return Int32(min(max(selectedFPS, 15), maximumBakeFPS))
    }

    private static func displayIDs(for screens: [NSScreen]?) -> [UInt32] {
        let targetScreens = (screens?.isEmpty == false) ? screens! : NSScreen.screens
        return targetScreens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    static func usableArtifact(from record: MediaDownloadRecord?) -> SceneBakeArtifact? {
        guard let record,
              let artifact = record.sceneBakeArtifact,
              isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) else {
            return nil
        }
        // Web bake: no eligibility snapshot; file presence is enough (same as recovery path).
        if artifact.renderer == .wallpaperEngineWeb {
            return artifact
        }
        // Scene bake: analysisId must still match eligibility when present.
        if let eligibilityId = record.sceneBakeEligibility?.analysisId,
           artifact.analysisId != eligibilityId {
            return nil
        }
        return artifact
    }

    @MainActor
    private static func downloadedRecord(forResolvedContentRoot contentRoot: URL) -> MediaDownloadRecord? {
        let resolvedContentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot)
        let resolvedPath = resolvedContentRoot.path
        if let exact = MediaLibraryService.shared.downloadRecord(forLocalFilePath: resolvedPath) {
            return exact
        }
        return MediaLibraryService.shared.downloadedItems.first { record in
            // SteamCMD stores a Workshop download at its outer `workshop_<id>` directory,
            // whose sibling content/downloads/temp folders prevent a generic root walk from
            // reaching the actual project. Use the record's canonical path comparison first.
            record.hasSameLocalContent(as: resolvedContentRoot)
                || WorkshopService.resolveWallpaperEngineProjectRoot(
                    startingAt: URL(fileURLWithPath: record.localFilePath)
                ).path == resolvedPath
        }
    }

    /// 实时渲染桌面后配套生成离线 MP4。
    /// 该 MP4 不会反向替换桌面实时渲染；如果动态锁屏开启，则烘焙完成后推送给对应显示器实例。
    @MainActor
    static func scheduleRealtimeCompanionBake(path: String, targetScreens: [NSScreen]? = nil, reason: String) {
        guard #available(macOS 26.0, *) else { return }
        let autoBakeEnabled = UserDefaults.standard.bool(forKey: "auto_bake_scene")
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path))
        guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(localFileURL: contentRoot) != nil else {
            print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): not a scene project \(contentRoot.path)")
            return
        }

        let displayIDs = displayIDs(for: targetScreens)

        Task(priority: .utility) {
            do {
                let record = await MainActor.run {
                    downloadedRecord(forResolvedContentRoot: contentRoot)
                }

                if let artifact = usableArtifact(from: record) {
                    await syncRealtimeBakeToLockScreen(artifact: artifact, itemID: record?.item.id, displayIDs: displayIDs, reason: reason)
                    print("[SceneOfflineBake] realtime companion bake cache hit (\(reason)): \(artifact.videoPath)")
                    return
                }

                guard autoBakeEnabled else {
                    print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): cache miss and auto_bake_scene is disabled")
                    return
                }

                let eligibility: SceneBakeEligibilitySnapshot
                if let existing = record?.sceneBakeEligibility,
                   existing.contentRootPath == contentRoot.path {
                    eligibility = existing
                } else {
                    guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                        print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): insufficient memory for analysis")
                        return
                    }
                    eligibility = try await Task.detached(priority: .utility) {
                        try SceneBakeEligibilityAnalyzer.analyze(contentRoot: contentRoot, intent: .desktopLoop, strict: false)
                    }.value
                    if let itemID = record?.item.id {
                        await MainActor.run {
                            MediaLibraryService.shared.attachSceneBakeEligibility(
                                itemID: itemID,
                                snapshot: eligibility,
                                triggerAutoBake: false
                            )
                        }
                    }
                }

                let itemID = record?.item.id
                let cacheItemID = itemID ?? stableOrphanCacheItemID(contentRootPath: contentRoot.path)
                let artifact = try await bake(
                    eligibility: eligibility,
                    contentRoot: contentRoot,
                    cacheItemID: cacheItemID,
                    renderer: .wallpaperWgpu,
                    persistArtifactToItemID: itemID,
                    progressItemID: itemID
                )
                print("[SceneOfflineBake] realtime companion bake finished (\(reason)): \(artifact.videoPath)")
                await syncRealtimeBakeToLockScreen(artifact: artifact, itemID: itemID, displayIDs: displayIDs, reason: reason)
            } catch {
                print("[SceneOfflineBake] realtime companion bake failed (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func syncRealtimeBakeToLockScreen(
        artifact: SceneBakeArtifact,
        itemID: String?,
        displayIDs: [UInt32],
        reason: String
    ) async {
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        guard isUsableBakedVideo(at: videoURL) else { return }

        if VideoWallpaperManager.shared.isLockScreenEnabled {
            // 动态锁屏开启：推送烘焙视频到锁屏实例
            guard !displayIDs.isEmpty else { return }
            let videoID = itemID ?? URL(fileURLWithPath: artifact.videoPath).deletingPathExtension().lastPathComponent
            await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
                videoURL: videoURL,
                videoID: videoID,
                displayIDs: displayIDs
            )
            print("[SceneOfflineBake] realtime companion bake synced lock screen (\(reason)): display=\(displayIDs) video=\(videoID)")
        } else {
            // 动态锁屏关闭：仅在系统壁纸同步开启时写桌面 poster。
            // 关闭同步时桌面由实时 scene 渲染，不得偷偷改系统壁纸。
            guard VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
                print("[SceneOfflineBake] 🧊 系统壁纸同步已关闭，跳过 companion bake 桌面 poster (\(reason))")
                return
            }
            guard let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                forLocalVideo: videoURL,
                fallbackPosterURL: nil
            ) else {
                print("[SceneOfflineBake] realtime companion bake could not generate desktop poster (\(reason)): \(videoURL.path)")
                return
            }
            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            // 只把 poster 推给目标显示器，绝不能写回 NSScreen.screens 全集 ——
            // 否则用户只在屏幕 N 上启用场景实时渲染时，烘焙完成会把静帧 poster
            // 顺手贴到其它屏的桌面（其它屏没有 wallpaper-wgpu 叠层挡着，直接可见）。
            // 入参 displayIDs 已由调用方按 targetScreens 精确指定，这里照单全收。
            let targetScreens: [NSScreen]
            if displayIDs.isEmpty {
                // 调用方未指定 → 退回历史行为（兼容无显示器信息的路径）
                targetScreens = NSScreen.screens
            } else {
                let idSet = Set(displayIDs)
                targetScreens = NSScreen.screens.filter { screen in
                    guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                        return false
                    }
                    return idSet.contains(n.uint32Value)
                }
            }
            guard !targetScreens.isEmpty else {
                print("[SceneOfflineBake] realtime companion bake has no matching display for desktop poster (\(reason)): display=\(displayIDs)")
                return
            }

            var appliedScreens = 0
            for screen in targetScreens {
                do {
                    try NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen, options: fillOptions)
                    appliedScreens += 1
                } catch {
                    print("[SceneOfflineBake] failed to set desktop poster (\(reason)) on \(screen.localizedName): \(error.localizedDescription)")
                }
            }
            print("[SceneOfflineBake] realtime companion bake set desktop poster (\(reason)) on \(appliedScreens)/\(targetScreens.count) screen(s) display=\(displayIDs): \(posterURL.path)")
        }
    }

    @MainActor
    static func isRendererAvailable(_ renderer: SceneBakeRenderer) -> Bool {
        switch renderer {
        case .wallpaperWgpu:
            return WallpaperEngineXBridge.resolvedCLIExecutableURL() != nil
        case .wallpaperEngineWeb:
            return WallpaperEngineXBridge.resolvedLegacyCLIExecutableURL() != nil
        }
    }

    @MainActor
    static func stopPreview() {
        ScenePreviewProcessController.shared.stop()
    }

    @MainActor
    static func preview(record: MediaDownloadRecord, renderer: SceneBakeRenderer) throws {
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        try preview(
            eligibility: eligibility,
            contentRoot: contentRoot,
            renderer: renderer
        )
    }

    @MainActor
    static func preview(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        renderer: SceneBakeRenderer
    ) throws {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }

        switch renderer {
        case .wallpaperWgpu:
            guard let cli = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
                throw SceneOfflineBakeError.cliNotFound
            }
            // 预览不传 `--wallpaper` / `--background`：保留一个普通可见窗口供用户查看，
            // 不要把窗口贴成桌面壁纸层级（壁纸层级会被其他窗口遮住，且鼠标事件全部穿透）。
            var args = [contentRoot.path]
            if let assets = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent(),
               !assets.isEmpty {
                args += ["--assets", assets]
            }
            try ScenePreviewProcessController.shared.launch(
                executableURL: cli,
                arguments: args,
                renderer: renderer
            )
        case .wallpaperEngineWeb:
            throw SceneOfflineBakeError.ineligible
        }
    }

    /// 缓存文件路径：`analysisId + 分辨率 + fps + 时长`（根目录为 `DownloadPathManager.sceneBakesFolderURL`）
    private static func cacheVideoURL(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        renderer: SceneBakeRenderer,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double,
        propertiesCacheKey: String?
    ) -> URL {
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = baseDir.appendingPathComponent(safeID, isDirectory: true)
        let propertiesSuffix = propertiesCacheKey.map { "_props-\($0)" } ?? ""
        let name =
            "\(analysisId.uuidString)_\(renderer.rawValue)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s\(propertiesSuffix).mp4"
        return dir.appendingPathComponent(name)
    }

    /// 设计面板属性会改变输出画面，必须参与缓存区分。
    private static func propertiesCacheKey(for userProperties: String?) -> String? {
        guard let userProperties,
              !userProperties.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let data: Data
        if let source = userProperties.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: source),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data = canonical
        } else {
            data = Data(userProperties.utf8)
        }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func rendererLaunchEnvironment(for executableURL: URL) -> [String: String] {
        let rendererDirectory = executableURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        let searchPaths = [
            rendererDirectory.path,
            rendererDirectory.deletingLastPathComponent().path,
            env["PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["PATH"] = searchPaths.joined(separator: ":")

        let libraryPaths = [
            rendererDirectory.appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("lib").path,
            rendererDirectory.appendingPathComponent("Resources").appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("Resources/lib").path,
            env["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["DYLD_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        return env
    }

    /// 无媒体库记录时（例如仅能从 Steam 目录解析到工程）用于缓存目录名的稳定 ID。
    static func stableOrphanCacheItemID(contentRootPath: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in contentRootPath.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return "orphan_\(hash)"
    }

    /// 与资格快照配套；`cacheItemID` 通常等于 `MediaItem.id`，无记录时用 `stableOrphanCacheItemID`。
    /// - Parameter persistArtifactToItemID: 非 nil 时将成品写回对应下载记录。
    /// - Parameter progressItemID: 用于跨详情页恢复的进度追踪 item id；默认取 `persistArtifactToItemID`。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        persistArtifactToItemID: String? = nil,
        progressItemID: String? = nil,
        resumingJobID: UUID? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(requestedFPS: fps)
        let effectiveDuration: Double
        if let durationSeconds {
            effectiveDuration = durationSeconds
        } else {
            let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
            effectiveDuration = saved >= 5 ? min(max(saved, 5), 60) : 15
        }
        let trackedItemID = progressItemID ?? persistArtifactToItemID
        let persistentJob = PersistentOfflineBakeJob.scene(
            id: resumingJobID ?? UUID(),
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: cacheItemID,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS,
            renderer: renderer,
            persistArtifactToItemID: persistArtifactToItemID,
            progressItemID: trackedItemID
        )
        let enqueueResult = await MainActor.run {
            SceneOfflineBakeProgressTracker.shared.enqueue(
                job: persistentJob,
                resumingJobID: resumingJobID
            )
        }
        guard enqueueResult.shouldExecute else {
            throw SceneOfflineBakeError.concurrentBakeInProgress
        }
        let jobID = enqueueResult.jobID

        await OfflineBakeSerialQueue.shared.waitForTurn(jobID: jobID)
        await MainActor.run {
            SceneOfflineBakeProgressTracker.shared.begin(jobID: jobID)
        }
        let trackedProgress: (@MainActor (Double) -> Void)? = { value in
            SceneOfflineBakeProgressTracker.shared.update(jobID: jobID, progress: value)
            progress?(value)
        }
        do {
            let result = try await bakeCore(
                eligibility: eligibility,
                contentRoot: contentRoot,
                cacheItemID: cacheItemID,
                durationSeconds: effectiveDuration,
                fps: effectiveFPS,
                renderer: renderer,
                persistArtifactToItemID: persistArtifactToItemID,
                progress: trackedProgress
            )
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: true)
                let bakedURL = URL(fileURLWithPath: result.videoPath)
                let title = persistArtifactToItemID.flatMap {
                    MediaLibraryService.shared.downloadRecord(for: $0)?.item.title
                } ?? bakedURL.deletingPathExtension().lastPathComponent
                VideoOptimizationQueueService.shared.registerBakedSource(
                    videoURL: bakedURL,
                    sourcePath: contentRoot.path,
                    artifact: result
                )
                _ = VideoOptimizationQueueService.shared.enqueueAfterBakeIfNeeded(
                    videoURL: bakedURL,
                    title: title
                )
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: result)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            return result
        } catch {
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: false)
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            throw error
        }
    }

    /// Re-enqueues unfinished checkpoint entries after relaunch. The original
    /// UUID is reused so recovery does not create a second visible queue item.
    @MainActor
    static func resumePersistedBakeQueue() async {
        let jobs = SceneOfflineBakeProgressTracker.shared.pendingPersistentJobs
        guard !jobs.isEmpty else { return }

        for job in jobs {
            switch job.kind {
            case .scene:
                guard let eligibility = job.eligibility,
                      let cacheItemID = job.cacheItemID else {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: "scene checkpoint is incomplete"
                    )
                    continue
                }
                do {
                    _ = try await bake(
                        eligibility: eligibility,
                        contentRoot: URL(fileURLWithPath: job.contentRootPath),
                        cacheItemID: cacheItemID,
                        durationSeconds: job.durationSeconds,
                        fps: Int32(job.fps),
                        renderer: job.renderer,
                        persistArtifactToItemID: job.persistArtifactToItemID,
                        progressItemID: job.progressItemID,
                        resumingJobID: job.id
                    )
                } catch {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: error.localizedDescription
                    )
                    print("[OfflineBakeQueue] restored scene bake failed: \(error.localizedDescription)")
                }

            case .web:
                do {
                    _ = try await WebOfflineBakeService.resumePersistedBakeJob(job)
                } catch {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: error.localizedDescription
                    )
                    print("[OfflineBakeQueue] restored web bake failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func bakeCore(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        renderer: SceneBakeRenderer,
        persistArtifactToItemID: String?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            throw SceneOfflineBakeError.insufficientMemory
        }

        let mainDisplaySize = mainDisplayPixelSize()
        let w = max(64, mainDisplaySize.width)
        let h = max(64, mainDisplaySize.height)
        let evenW = (w / 2) * 2
        let evenH = (h / 2) * 2
        let effectiveUserProperties = await MainActor.run {
            SceneConfigOverrideService.mergedPropertiesJSON(
                userPropertiesJSON: SceneWallpaperPropertiesService.propertiesOverrideJSON(for: contentRoot.path),
                for: contentRoot.path
            )
        }

        let sceneBakesRoot = await MainActor.run {
            DownloadPathManager.shared.sceneBakesFolderURL
        }
        let cacheDurationSeconds = durationSeconds
        let outURL = cacheVideoURL(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            renderer: renderer,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: cacheDurationSeconds,
            propertiesCacheKey: propertiesCacheKey(for: effectiveUserProperties)
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cachedInspection: BakedVideoInspection? = await {
            switch renderer {
            case .wallpaperWgpu:
                return await inspectBakedVideo(at: outURL, expectedWidth: evenW, expectedHeight: evenH)
            case .wallpaperEngineWeb:
                return nil
            }
        }()
        if let cachedInspection,
           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path) {
            let artifact = SceneBakeArtifact(
                analysisId: eligibility.analysisId,
                videoPath: outURL.path,
                width: cachedInspection.width,
                height: cachedInspection.height,
                fps: Int(fps),
                durationSeconds: durationSeconds,
                bakedAt: (attrs[.creationDate] as? Date) ?? .now,
                renderer: renderer
            )
            if let itemID = persistArtifactToItemID {
                await MainActor.run {
                    MediaLibraryService.shared.attachSceneBakeArtifact(
                        itemID: itemID,
                        artifact: artifact,
                        regeneratePoster: false
                    )
                }
                await regenerateSceneBakePosterAndNotify(
                    itemID: itemID,
                    videoURL: URL(fileURLWithPath: artifact.videoPath)
                )
            }
            return artifact
        }
        if FileManager.default.fileExists(atPath: outURL.path) {
            print("[SceneOfflineBake] removing invalid cached MP4: \(outURL.path)")
            try? FileManager.default.removeItem(at: outURL)
        }

        let artifact: SceneBakeArtifact
        switch renderer {
        case .wallpaperWgpu:
            artifact = try await bakeWithWallpaperWgpu(
                contentRoot: contentRoot,
                outURL: outURL,
                eligibility: eligibility,
                width: evenW,
                height: evenH,
                fps: fps,
                durationSeconds: durationSeconds,
                userProperties: effectiveUserProperties,
                progress: progress
            )
        case .wallpaperEngineWeb:
            throw SceneOfflineBakeError.ineligible
        }
        if let itemID = persistArtifactToItemID {
            await MainActor.run {
                MediaLibraryService.shared.attachSceneBakeArtifact(
                    itemID: itemID,
                    artifact: artifact,
                    regeneratePoster: false
                )
            }
            await regenerateSceneBakePosterAndNotify(
                itemID: itemID,
                videoURL: URL(fileURLWithPath: artifact.videoPath)
            )
        }

        return artifact
    }

    private static func bakeWithWallpaperWgpu(
        contentRoot: URL,
        outURL: URL,
        eligibility: SceneBakeEligibilitySnapshot,
        width: Int,
        height: Int,
        fps: Int32,
        durationSeconds: Double,
        userProperties: String?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        // 使用 wallpaper-wgpu bake 子命令（GPU readback 直接编码，不需要屏幕录制）
        guard let wgpuBinary = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            throw SceneOfflineBakeError.cliNotFound
        }

        let tempURL = outURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        // wallpaper-wgpu bake <path> --size WxH --fps N --duration S --out <path> [--assets <path>] [--clean]
        var args: [String] = [
            "bake",
            contentRoot.path,
            "--size", "\(width)x\(height)",
            "--fps", String(fps),
            "--clean",
            "--out", tempURL.path,
        ]

        // assets 路径（异步等待解压完成）
        if let assets = await WallpaperEngineEmbeddedAssets.awaitAssetsReady(), !assets.isEmpty {
            args += ["--assets", assets]
        }

        if let userProperties, !userProperties.isEmpty {
            args += ["--user-properties", userProperties]
        }

        // 自动检测周期时不需要传 --duration，让 bake 自己检测
        if durationSeconds > 0 {
            args += ["--duration", String(Int(durationSeconds))]
        }

        print("[SceneOfflineBake] 启动 wallpaper-wgpu bake: \(wgpuBinary.lastPathComponent) \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = wgpuBinary
        process.currentDirectoryURL = wgpuBinary.deletingLastPathComponent()
        process.arguments = args
        var env = SceneOfflineBakeService.rendererLaunchEnvironment(for: wgpuBinary)
        env["RUST_LOG"] = env["RUST_LOG"] ?? "warn"
        process.environment = env

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try process.run()

        final class StderrCapture: @unchecked Sendable {
            private let maxTailBytes = 256 * 1024
            var tail = Data()
            let logURL: URL
            let logHandle: FileHandle?

            init() {
                logURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("waifux-wallpaper-wgpu-bake-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                logHandle = try? FileHandle(forWritingTo: logURL)
            }

            func append(_ data: Data) {
                logHandle?.write(data)
                tail.append(data)
                if tail.count > maxTailBytes {
                    tail.removeFirst(tail.count - maxTailBytes)
                }
            }

            func close() {
                try? logHandle?.close()
            }
        }
        let stderrCapture = StderrCapture()

        // stdout 捕获：收集 DYNAMIC_TEXTS / IMAGES / AUDIO_SPECTRUM / AUDIO_VISUALIZERS JSON
        final class StdoutCapture: @unchecked Sendable {
            var data = Data()
            func append(_ chunk: Data) {
                data.append(chunk)
            }
            /// 解析 DYNAMIC_TEXTS: 行并返回 JSON Data
            func dynamicTextsJSON() -> Data? {
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("DYNAMIC_TEXTS:") {
                        let jsonStr = String(trimmed.dropFirst(14))
                        return jsonStr.data(using: .utf8)
                    }
                }
                return nil
            }
            /// 解析 IMAGES: 行并返回 JSON Data
            func imagesJSON() -> Data? {
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("IMAGES:") {
                        let jsonStr = String(trimmed.dropFirst(7))
                        return jsonStr.data(using: .utf8)
                    }
                }
                return nil
            }
        }
        let stdoutCapture = StdoutCapture()

        final class WallpaperWgpuBakeProgressParser: @unchecked Sendable {
            private let phaseFramePattern = try? NSRegularExpression(
                pattern: #"^\s*\[bake\]\s*(预热|录制|编码|完成)\s+(\d+)/(\d+)\s+\[(\d+(?:\.\d+)?)%\]"#
            )
            private let phaseTotalPattern = try? NSRegularExpression(
                pattern: #"^\s*\[bake\]\s*(预热|录制)\s+(\d+)\s+帧"#
            )
            private let percentPattern = try? NSRegularExpression(pattern: #"\[(\d+(?:\.\d+)?)%\]"#)

            private var warmupFrames: Double?
            private var recordingFrames: Double?
            private var lastProgress: Double = 0

            func progress(from line: String) -> Double? {
                updatePhaseTotals(from: line)

                if let progress = progressFromPhaseFrameLine(line) {
                    return publish(progress)
                }

                guard let pct = progressPercent(in: line) else {
                    return nil
                }
                let phaseProgress = pct / 100.0
                if line.contains("预热") {
                    return publish(mapPhaseProgress(phase: "预热", current: phaseProgress, total: 1))
                }
                if line.contains("录制") {
                    return publish(mapPhaseProgress(phase: "录制", current: phaseProgress, total: 1))
                }
                if line.contains("编码") {
                    return publish(0.98)
                }
                return publish(phaseProgress)
            }

            private func updatePhaseTotals(from line: String) {
                guard let match = phaseTotalPattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let phaseRange = Range(match.range(at: 1), in: line),
                   let totalRange = Range(match.range(at: 2), in: line),
                   let total = Double(line[totalRange]) else {
                    return
                }

                switch String(line[phaseRange]) {
                case "预热":
                    warmupFrames = total
                case "录制":
                    recordingFrames = total
                default:
                    break
                }
            }

            private func progressFromPhaseFrameLine(_ line: String) -> Double? {
                guard let match = phaseFramePattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let phaseRange = Range(match.range(at: 1), in: line),
                   let currentRange = Range(match.range(at: 2), in: line),
                   let totalRange = Range(match.range(at: 3), in: line),
                   let pctRange = Range(match.range(at: 4), in: line),
                   let current = Double(line[currentRange]),
                   let total = Double(line[totalRange]),
                   let pct = Double(line[pctRange]) else {
                    return nil
                }

                let phase = String(line[phaseRange])
                if isGlobalProgress(phase: phase, total: total) {
                    return pct / 100.0
                }
                return mapPhaseProgress(phase: phase, current: current, total: total)
            }

            private func isGlobalProgress(phase: String, total: Double) -> Bool {
                switch phase {
                case "预热":
                    if let warmupFrames {
                        return abs(total - warmupFrames) > 0.5
                    }
                case "录制":
                    if let recordingFrames {
                        return abs(total - recordingFrames) > 0.5
                    }
                default:
                    break
                }
                return false
            }

            private func mapPhaseProgress(phase: String, current: Double, total: Double) -> Double {
                let warmupWeight = 0.20
                let recordingCeiling = 0.98
                let phaseProgress = total > 0 ? min(max(current / total, 0), 1) : 0

                switch phase {
                case "预热":
                    return phaseProgress * warmupWeight
                case "录制":
                    return warmupWeight + phaseProgress * (recordingCeiling - warmupWeight)
                case "编码":
                    return recordingCeiling
                case "完成":
                    return 1.0
                default:
                    return phaseProgress
                }
            }

            private func progressPercent(in line: String) -> Double? {
                guard let match = percentPattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let range = Range(match.range(at: 1), in: line) else {
                    return nil
                }
                return Double(line[range])
            }

            private func publish(_ progress: Double) -> Double? {
                let clamped = min(max(progress, 0.0), 0.99)
                guard clamped >= lastProgress || clamped >= 0.99 else {
                    return nil
                }
                lastProgress = max(lastProgress, clamped)
                return lastProgress
            }
        }

        // 监控 stderr 中的进度信息。兼容旧版阶段内百分比和新版全局百分比。
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let progressTask = Task.detached(priority: .utility) {
            let progressParser = WallpaperWgpuBakeProgressParser()
            var buffer = ""
            while !Task.isCancelled {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                stderrCapture.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    buffer += chunk
                    let lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    buffer = lines.last ?? ""
                    for line in lines.dropLast() where !line.isEmpty {
                        if let parsedProgress = progressParser.progress(from: line) {
                            await progress?(parsedProgress)
                        }
                    }
                }
            }
            // 处理缓冲区中剩余内容
            if !buffer.isEmpty, let parsedProgress = progressParser.progress(from: buffer) {
                await progress?(parsedProgress)
            }
        }

        // 读取 stdout（DYNAMIC_TEXTS 等 JSON 数据）
        let stdoutTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let data = stdoutHandle.availableData
                if data.isEmpty { break }
                stdoutCapture.append(data)
            }
        }

        // 用轮询替代 waitUntilExit，避免阻塞 cooperative thread pool
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await progressTask.value
        await stdoutTask.value
        stderrCapture.close()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            let stderrString = String(data: stderrCapture.tail, encoding: .utf8) ?? ""
            let cleanStderr = stderrString
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    !$0.isEmpty
                    && !$0.contains(" INFO ")
                    && !$0.hasPrefix("[bake] 预热 ")
                    && !$0.hasPrefix("[bake] 烘焙 ")
                }
                .suffix(20)
                .joined(separator: "\n")
            let message = cleanStderr.isEmpty
                ? "wallpaper-wgpu bake 执行失败 (exit=\(process.terminationStatus))\n完整日志: \(stderrCapture.logURL.path)"
                : "wallpaper-wgpu bake 执行失败 (exit=\(process.terminationStatus))\n\(cleanStderr)\n完整日志: \(stderrCapture.logURL.path)"
            throw SceneOfflineBakeError.bakeProcessFailed(message)
        }

        guard await inspectBakedVideo(at: tempURL, expectedWidth: width, expectedHeight: height) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outURL)
            throw SceneOfflineBakeError.bakeProcessFailed("bake 完成后未找到输出文件")
        }
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tempURL, to: outURL)

        // 写入 sidecar JSON（动态文本 + 图片数据）
        let sidecarURL = outURL.deletingPathExtension().appendingPathExtension("json")
        if var sidecarDict = stdoutCapture.dynamicTextsJSON().flatMap({
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) {
            // 合并 IMAGES 数据到 sidecar
            if let imagesData = stdoutCapture.imagesJSON(),
               let imagesDict = try? JSONSerialization.jsonObject(with: imagesData) as? [String: Any],
               let images = imagesDict["images"] {
                sidecarDict["images"] = images
            }
            if let mergedData = try? JSONSerialization.data(withJSONObject: sidecarDict, options: [.sortedKeys, .withoutEscapingSlashes]) {
                try? mergedData.write(to: sidecarURL, options: .atomic)
                print("[SceneOfflineBake] wallpaper-wgpu sidecar JSON 已写入: \(sidecarURL.lastPathComponent)")
            }
        }

        await MainActor.run { progress?(1.0) }

        return SceneBakeArtifact(
            analysisId: eligibility.analysisId,
            videoPath: outURL.path,
            width: width,
            height: height,
            fps: Int(fps),
            durationSeconds: durationSeconds,
            bakedAt: .now,
            renderer: .wallpaperWgpu
        )
    }

    /// 检查是否有缓存（不触发实际烘焙）
    static func hasCachedArtifact(record: MediaDownloadRecord, renderer: SceneBakeRenderer? = nil) -> Bool {
        guard let art = usableArtifact(from: record) else { return false }
        if let renderer {
            return art.renderer == renderer
        }
        return true
    }

    /// 与 `MediaDownloadRecord.sceneBakeEligibility` 配套；默认主屏逻辑分辨率 × scale。
    /// FPS 默认值取自用户设置 `scene_bake_fps`（回退 30），且不超过显示器最高刷新率。
    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(requestedFPS: fps)
        let effectiveDuration: Double
        if let durationSeconds {
            effectiveDuration = durationSeconds
        } else {
            let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
            effectiveDuration = saved >= 5 ? min(max(saved, 5), 60) : 15
        }
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        return try await bake(
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: record.id,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS,
            renderer: renderer,
            persistArtifactToItemID: record.id,
            progressItemID: record.item.id,
            progress: progress
        )
    }

    /// 资格写入后后台自动烘焙（推荐/边缘档位）；已有同 `analysisId` 成品则跳过。
    static func scheduleAutoBakeAfterEligibility(itemID: String) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let record = await MainActor.run { () -> MediaDownloadRecord? in
                MediaLibraryService.shared.downloadedItems.first { $0.item.id == itemID }
            }
            guard let record,
                  let eligibility = record.sceneBakeEligibility else { return }
            if let art = record.sceneBakeArtifact,
               art.analysisId == eligibility.analysisId,
               (art.renderer == nil || art.renderer == .wallpaperWgpu),
               isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                return
            }
            do {
                // 进度由 SceneOfflineBakeProgressTracker 统一广播
                _ = try await bake(record: record)
                print("[SceneOfflineBake] auto-bake finished \(itemID)")
            } catch {
                print("[SceneOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
            }
        }
    }

    /// Lightweight, main-thread-safe gate: file exists and is non-trivial.
    /// Avoids AVAsset + semaphore on the main actor (that path deadlocked /
    /// starved set-wallpaper when a bake product was present).
    static func isUsableBakedVideo(at url: URL) -> Bool {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 10_000 else {
            return false
        }
        return true
    }

    private static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 1
        let width = max(64, Int((frame.width * scale).rounded()))
        let height = max(64, Int((frame.height * scale).rounded()))
        print("[SceneOfflineBake] main display pixels: \(width)x\(height) (frame=\(Int(frame.width))x\(Int(frame.height)), scale=\(scale))")
        return (width, height)
    }

    private static func inspectBakedVideo(at url: URL, expectedWidth: Int? = nil, expectedHeight: Int? = nil) async -> BakedVideoInspection? {
        guard isUsableBakedVideo(at: url) else { return nil }

        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        guard let durationSec = duration?.seconds, durationSec.isFinite, durationSec > 0.5 else { return nil }
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(Int(transformedSize.width.rounded()))
        let height = abs(Int(transformedSize.height.rounded()))
        guard width > 0, height > 0 else { return nil }
        if let expectedWidth, let expectedHeight, (width != expectedWidth || height != expectedHeight) {
            print("[SceneOfflineBake] invalid cached MP4 size: actual=\(width)x\(height) expected=\(expectedWidth)x\(expectedHeight) url=\(url.path)")
            return nil
        }
        return BakedVideoInspection(duration: durationSec, width: width, height: height)
    }
}
