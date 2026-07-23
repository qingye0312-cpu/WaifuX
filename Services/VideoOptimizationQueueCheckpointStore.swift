import Foundation

/// Persists unfinished video-optimization queue work across application relaunch.
///
/// Terminal outcomes remain in the media-adjacent sidecar. A checkpoint only
/// describes work that can safely be re-run from the original source file, plus
/// optional source-restore requests that should survive relaunch while a
/// re-download is still outstanding.
struct VideoOptimizationQueueCheckpointStore {
    private struct Snapshot: Codable {
        let version: Int
        let items: [Item]
        let sourceRestoreRequests: [SourceRestoreRequest]?
    }

    struct RestoredState {
        let items: [FrameInterpolationQueueItem]
        let sourceRestoreRequests: [SourceRestoreRequest]
    }

    /// A restore request is unfinished pipeline work too: the downloaded file
    /// might arrive after the app relaunches, so its requested retry or
    /// blacklist operation must not depend on a live detail sheet.
    struct SourceRestoreRequest: Codable {
        let videoPath: String
        let title: String?
        let targetFPS: Int
        let operations: [FrameInterpolationQueueItem.Operation]
        let blacklistOperation: FrameInterpolationQueueItem.Operation?

        static func enqueue(
            videoURL: URL,
            title: String?,
            targetFPS: Int,
            operations: [FrameInterpolationQueueItem.Operation]
        ) -> SourceRestoreRequest {
            SourceRestoreRequest(
                videoPath: videoURL.standardizedFileURL.path,
                title: title,
                targetFPS: targetFPS,
                operations: operations,
                blacklistOperation: nil
            )
        }

        static func blacklist(
            videoURL: URL,
            title: String?,
            targetFPS: Int,
            operation: FrameInterpolationQueueItem.Operation
        ) -> SourceRestoreRequest {
            SourceRestoreRequest(
                videoPath: videoURL.standardizedFileURL.path,
                title: title,
                targetFPS: targetFPS,
                operations: [],
                blacklistOperation: operation
            )
        }

        func normalizedForRestore() -> SourceRestoreRequest? {
            guard blacklistOperation == nil else { return self }
            // Prefer a single first operation on restore.
            if operations.contains(.loopTransition) {
                return SourceRestoreRequest(
                    videoPath: videoPath,
                    title: title,
                    targetFPS: targetFPS,
                    operations: [.loopTransition],
                    blacklistOperation: nil
                )
            }
            if operations.contains(.frameInterpolation) {
                return SourceRestoreRequest(
                    videoPath: videoPath,
                    title: title,
                    targetFPS: targetFPS,
                    operations: [.frameInterpolation],
                    blacklistOperation: nil
                )
            }
            return operations.isEmpty ? nil : self
        }
    }

    private struct Item: Codable {
        let id: UUID
        let videoPath: String
        let title: String
        let targetFPS: Int
        let source: FrameInterpolationQueueItem.Source
        let operations: [FrameInterpolationQueueItem.Operation]
        let completedOperations: [FrameInterpolationQueueItem.Operation]
        let addedAt: Date

        init(queueItem: FrameInterpolationQueueItem) {
            id = queueItem.id
            videoPath = queueItem.videoURL.standardizedFileURL.path
            title = queueItem.title
            targetFPS = queueItem.targetFPS
            source = queueItem.source
            operations = queueItem.operations
            completedOperations = Array(queueItem.completedOperations)
            addedAt = queueItem.addedAt
        }

        func restoredQueueItem() -> FrameInterpolationQueueItem? {
            let videoURL = URL(fileURLWithPath: videoPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                return nil
            }

            let completed = Set(completedOperations)
            let pendingOperations = operations.filter { !completed.contains($0) }
            guard !pendingOperations.isEmpty else {
                return nil
            }

            return FrameInterpolationQueueItem(
                id: id,
                videoURL: videoURL,
                title: title,
                targetFPS: targetFPS,
                source: source,
                operations: pendingOperations,
                completedOperations: [],
                currentOperation: nil,
                sourceFPS: nil,
                status: .waiting,
                progress: 0,
                writtenFrames: 0,
                totalFrames: nil,
                opticalFlowFrames: 0,
                elapsedSeconds: 0,
                remainingSeconds: nil,
                currentStage: t("frameInterpolationStageWaiting"),
                outputURL: nil,
                addedAt: addedAt
            )
        }
    }

    static let shared = VideoOptimizationQueueCheckpointStore()

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Backward-compatible load used by existing callers.
    func load() -> [FrameInterpolationQueueItem] {
        loadState().items
    }

    func loadState() -> RestoredState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return RestoredState(items: [], sourceRestoreRequests: [])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return RestoredState(items: [], sourceRestoreRequests: [])
        }
        return RestoredState(
            items: snapshot.items.compactMap { $0.restoredQueueItem() },
            sourceRestoreRequests: (snapshot.sourceRestoreRequests ?? []).compactMap {
                $0.normalizedForRestore()
            }
        )
    }

    /// Backward-compatible save used by existing callers.
    func save(_ items: [FrameInterpolationQueueItem]) {
        save(items, sourceRestoreRequests: [])
    }

    func save(
        _ items: [FrameInterpolationQueueItem],
        sourceRestoreRequests: [SourceRestoreRequest]
    ) {
        let pendingItems = items.filter { !$0.isTerminalForCleanup }
        guard !pendingItems.isEmpty || !sourceRestoreRequests.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let snapshot = Snapshot(
            version: 1,
            items: pendingItems.map(Item.init(queueItem:)),
            sourceRestoreRequests: sourceRestoreRequests
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            frameInterpolationDebugPrint(
                "视频优化队列：写入断点失败。路径=\(fileURL.path)，原因=\(error.localizedDescription)"
            )
        }
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("VideoOptimization", isDirectory: true)
            .appendingPathComponent("pending-queue.json")
    }
}
