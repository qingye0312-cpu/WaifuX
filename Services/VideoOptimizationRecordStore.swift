import Foundation

/// Persists durable terminal optimization state adjacent to the media file.
///
/// The queue remains responsible for scheduling and UI state. This store only
/// records lifecycle events and source provenance so a library rebuild,
/// re-download, or application restart cannot make a replaced file look
/// untouched or inherit a previous file's terminal outcomes.
@MainActor
final class VideoOptimizationRecordStore {
    static let shared = VideoOptimizationRecordStore()

    enum EventKind: String, Codable, Hashable {
        case sourceDownloaded
        case bakeCompleted
        case loopApplied
        case loopNotNeeded
        case loopNoReliablePoint
        case loopFailed
        case loopCancelled
        case frameQueued
        case frameStarted
        case frameApplied
        case frameNotNeeded
        case frameFailed
        case frameCancelled
        case frameBlacklisted
    }

    /// How this exact video file came to exist. Stored beside the file rather
    /// than inferred from a library cache entry.
    enum SourceKind: String, Codable, Equatable {
        case download
        case sceneBake
        case imported
        case unknown
    }

    struct SourceInfo: Codable, Equatable {
        var kind: SourceKind
        var sourceURL: String?
        var sourcePath: String?
        var recordedAt: Date
    }

    enum DownloadStatus: String, Codable, Equatable {
        case completed
    }

    struct DownloadInfo: Codable, Equatable {
        var status: DownloadStatus
        var sourceURL: String?
        var completedAt: Date
    }

    enum BakeStatus: String, Codable, Equatable {
        case completed
    }

    struct BakeInfo: Codable, Equatable {
        var status: BakeStatus
        var sourcePath: String
        var artifactPath: String
        var renderer: String?
        var durationSeconds: Double?
        var framesPerSecond: Int?
        var width: Int?
        var height: Int?
        var completedAt: Date
    }

    struct Event: Codable, Equatable, Identifiable {
        let id: UUID
        let date: Date
        let kind: EventKind
        let detail: String?
        let metadata: [String: String]

        init(kind: EventKind, detail: String? = nil, metadata: [String: String] = [:]) {
            self.id = UUID()
            self.date = Date()
            self.kind = kind
            self.detail = detail
            self.metadata = metadata
        }
    }

    struct Record: Codable, Equatable {
        /// Provenance first so the human-readable sidecar is easy to inspect.
        /// Older schema v1 sidecars decode because these fields are optional.
        var source: SourceInfo?
        var download: DownloadInfo?
        var bake: BakeInfo?
        let schemaVersion: Int
        let videoPath: String
        let createdAt: Date
        var updatedAt: Date
        var events: [Event]

        init(videoURL: URL) {
            let now = Date()
            source = SourceInfo(
                kind: .unknown,
                sourceURL: nil,
                sourcePath: nil,
                recordedAt: now
            )
            download = nil
            bake = nil
            schemaVersion = 3
            videoPath = videoURL.standardizedFileURL.path
            createdAt = now
            updatedAt = now
            events = []
        }
    }

    enum LoopState: Equatable {
        case idle
        case applied
        case notNeeded
        case noReliablePoint
        case failed
    }

    enum FrameState: Equatable {
        case idle
        case applied(targetFPS: Int?)
        case notNeeded(targetFPS: Int?)
        case failed
        case blacklisted
    }

    enum OptimizationState: Equatable {
        case idle
        case completed
        case notNeeded
        case failed
        case blacklisted
    }

    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv"
    ]

    private init() {}

    func sidecarURL(for videoURL: URL) -> URL {
        URL(fileURLWithPath: videoURL.standardizedFileURL.path + ".waifux-optimization.json")
    }

    func record(for videoURL: URL) -> Record? {
        guard isVideoFile(videoURL),
              let data = try? Data(contentsOf: sidecarURL(for: videoURL)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    @discardableResult
    func append(
        _ kind: EventKind,
        for videoURL: URL,
        detail: String? = nil,
        metadata: [String: String] = [:]
    ) -> Bool {
        guard isVideoFile(videoURL) else { return false }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        record.events.append(Event(kind: kind, detail: detail, metadata: metadata))
        record.updatedAt = Date()
        return write(record, for: videoURL)
    }

    /// Registers a completed download as the source of this exact video.
    /// Callers that need a clean lifecycle should reset the old sidecar first.
    func recordDownloadedSource(for videoURL: URL, sourceURL: URL?) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        let now = Date()
        let sourceURLString = sourceURL?.absoluteString
        record.source = SourceInfo(
            kind: .download,
            sourceURL: sourceURLString,
            sourcePath: nil,
            recordedAt: now
        )
        record.download = DownloadInfo(
            status: .completed,
            sourceURL: sourceURLString,
            completedAt: now
        )
        record.events.append(Event(kind: .sourceDownloaded, metadata: compactMetadata([
            "sourceURL": sourceURLString
        ])))
        record.updatedAt = now
        _ = write(record, for: videoURL)
    }

    /// Gives pre-existing local files a durable origin the first time they are
    /// applied or optimized. Download and Scene bake later replace this
    /// fallback with more specific provenance.
    func recordImportedSourceIfNeeded(for videoURL: URL) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        guard record.source == nil || record.source?.kind == .unknown else { return }

        let now = Date()
        record.source = SourceInfo(
            kind: .imported,
            sourceURL: nil,
            sourcePath: videoURL.standardizedFileURL.path,
            recordedAt: now
        )
        record.updatedAt = now
        _ = write(record, for: videoURL)
    }

    /// Stores the Scene project and output parameters that produced a baked MP4.
    func recordBakeArtifact(
        for videoURL: URL,
        sourcePath: String,
        artifact: SceneBakeArtifact
    ) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        let now = Date()
        let bakedAt = Date(timeIntervalSince1970: artifact.bakedAt.timeIntervalSince1970.rounded(.down))
        let source = SourceInfo(
            kind: .sceneBake,
            sourceURL: nil,
            sourcePath: sourcePath,
            recordedAt: bakedAt
        )
        let bake = BakeInfo(
            status: .completed,
            sourcePath: sourcePath,
            artifactPath: videoURL.standardizedFileURL.path,
            renderer: artifact.renderer?.rawValue,
            durationSeconds: artifact.durationSeconds,
            framesPerSecond: artifact.fps,
            width: artifact.width,
            height: artifact.height,
            completedAt: bakedAt
        )
        guard record.source != source || record.bake != bake else { return }

        record.source = source
        record.bake = bake
        record.events.append(Event(kind: .bakeCompleted, metadata: compactMetadata([
            "sourcePath": sourcePath,
            "renderer": artifact.renderer?.rawValue,
            "durationSeconds": String(artifact.durationSeconds),
            "fps": String(artifact.fps),
            "width": String(artifact.width),
            "height": String(artifact.height)
        ])))
        record.updatedAt = now
        _ = write(record, for: videoURL)
    }

    func latestLoopEvent(for videoURL: URL) -> Event? {
        record(for: videoURL)?.events.reversed().first {
            switch $0.kind {
            case .loopApplied, .loopNotNeeded, .loopNoReliablePoint, .loopFailed:
                return true
            case .sourceDownloaded, .bakeCompleted, .loopCancelled,
                 .frameQueued, .frameStarted, .frameApplied, .frameNotNeeded,
                 .frameFailed, .frameCancelled, .frameBlacklisted:
                return false
            }
        }
    }

    func latestFrameEvent(for videoURL: URL) -> Event? {
        record(for: videoURL)?.events.reversed().first {
            switch $0.kind {
            case .frameApplied, .frameNotNeeded, .frameFailed, .frameBlacklisted:
                return true
            case .sourceDownloaded, .bakeCompleted,
                 .loopApplied, .loopNotNeeded, .loopNoReliablePoint,
                 .loopFailed, .loopCancelled,
                 .frameQueued, .frameStarted, .frameCancelled:
                return false
            }
        }
    }

    /// Converts durable loop terminal events into the state shown outside the queue.
    func loopState(for videoURL: URL) -> LoopState {
        guard let event = latestLoopEvent(for: videoURL) else { return .idle }
        switch event.kind {
        case .loopApplied:
            return .applied
        case .loopNotNeeded:
            return .notNeeded
        case .loopNoReliablePoint:
            return .noReliablePoint
        case .loopFailed:
            return .failed
        case .sourceDownloaded, .bakeCompleted, .loopCancelled,
             .frameQueued, .frameStarted, .frameApplied, .frameNotNeeded,
             .frameFailed, .frameCancelled, .frameBlacklisted:
            return .idle
        }
    }

    func frameState(for videoURL: URL) -> FrameState {
        guard let event = latestFrameEvent(for: videoURL) else { return .idle }
        let targetFPS = event.metadata["targetFPS"].flatMap(Int.init)
        switch event.kind {
        case .frameApplied:
            return .applied(targetFPS: targetFPS)
        case .frameNotNeeded:
            return .notNeeded(targetFPS: targetFPS)
        case .frameFailed:
            return .failed
        case .frameBlacklisted:
            return .blacklisted
        case .sourceDownloaded, .bakeCompleted,
             .loopApplied, .loopNotNeeded, .loopNoReliablePoint,
             .loopFailed, .loopCancelled,
             .frameQueued, .frameStarted, .frameCancelled:
            return .idle
        }
    }

    /// Derives the whole-pipeline result from the durable sidecar events.
    /// Scene bake provenance satisfies the loop stage by design; ordinary videos
    /// require a terminal loop judgment before the overall result is complete.
    func optimizationState(for videoURL: URL, targetFPS: Int) -> OptimizationState {
        let record = record(for: videoURL)
        let isSceneBake = record?.source?.kind == .sceneBake
        let loop = loopState(for: videoURL)
        let frame = frameState(for: videoURL)

        if frame == .blacklisted { return .blacklisted }
        if loop == .failed || frame == .failed { return .failed }

        let loopResolved: Bool
        let loopChangedFile: Bool
        if isSceneBake {
            loopResolved = true
            loopChangedFile = false
        } else {
            switch loop {
            case .applied:
                loopResolved = true
                loopChangedFile = true
            case .notNeeded, .noReliablePoint:
                loopResolved = true
                loopChangedFile = false
            case .idle, .failed:
                loopResolved = false
                loopChangedFile = false
            }
        }

        let frameResolved: Bool
        let frameChangedFile: Bool
        switch frame {
        case .applied(let appliedTarget):
            frameResolved = (appliedTarget ?? 0) >= targetFPS
            frameChangedFile = frameResolved
        case .notNeeded(let checkedTarget):
            frameResolved = (checkedTarget ?? 0) >= targetFPS
            frameChangedFile = false
        case .idle, .failed, .blacklisted:
            frameResolved = false
            frameChangedFile = false
        }

        guard loopResolved, frameResolved else { return .idle }
        return loopChangedFile || frameChangedFile ? .completed : .notNeeded
    }

    @discardableResult
    func removeEvents(
        matching kinds: Set<EventKind>,
        for videoURL: URL
    ) -> Bool {
        guard var record = record(for: videoURL) else { return true }
        record.events.removeAll { kinds.contains($0.kind) }
        record.updatedAt = Date()
        return write(record, for: videoURL)
    }

    @discardableResult
    func reset(for videoURL: URL) -> Bool {
        let sidecarURL = sidecarURL(for: videoURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: sidecarURL)
            return true
        } catch {
            return false
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func compactMetadata(_ metadata: [String: String?]) -> [String: String] {
        metadata.reduce(into: [:]) { result, entry in
            if let value = entry.value, !value.isEmpty {
                result[entry.key] = value
            }
        }
    }

    private func write(_ record: Record, for videoURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return false }

        do {
            try data.write(to: sidecarURL(for: videoURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
