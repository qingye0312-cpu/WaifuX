import AppKit
import AVFoundation
import CryptoKit
import Foundation

/// Exports Wallpaper Engine Web projects through the bundled WebKit renderer.
///
/// The renderer runs in a dedicated CLI process with an offscreen WKWebView, so
/// baking neither replaces nor pauses the user's currently applied wallpaper.
///
/// Cache naming matches scene bake:
/// `{analysisId}_{renderer}_{w}x{h}_{fps}fps_{duration}s[_props-{hash}].mp4`
enum WebOfflineBakeService {
    private struct VideoInspection {
        let duration: TimeInterval
        let width: Int
        let height: Int
    }

    private static var maximumBakeFPS: Double {
        Double(NSScreen.screens.map(\.maxRefreshRate).max() ?? 60)
    }

    static func isWebProject(at localURL: URL) -> Bool {
        let root = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localURL)
        let projectURL = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return false
        }
        return type.caseInsensitiveCompare("web") == .orderedSame
    }

    /// Stable id derived from project.json (+ mtime), same role as scene eligibility analysisId.
    static func stableAnalysisId(for contentRoot: URL) -> UUID {
        let projectURL = contentRoot.appendingPathComponent("project.json")
        var data = (try? Data(contentsOf: projectURL)) ?? Data(contentRoot.path.utf8)
        if let date = try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            data.append(Data(String(date.timeIntervalSince1970).utf8))
        }
        let digest = Array(SHA256.hash(data: data))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            (digest[6] & 0x0f) | 0x50, digest[7],
            (digest[8] & 0x3f) | 0x80, digest[9],
            digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        resumingJobID: UUID? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: record.localFileURL)
        guard isWebProject(at: contentRoot) else {
            throw SceneOfflineBakeError.ineligible
        }
        guard let cli = WallpaperEngineXBridge.resolvedLegacyCLIExecutableURL() else {
            throw SceneOfflineBakeError.webCliNotFound
        }

        let analysisId = stableAnalysisId(for: contentRoot)
        let effectiveFPS = resolvedFPS(requested: fps)
        let effectiveDuration = resolvedDuration(requested: durationSeconds)
        let targetSize = mainDisplayPixelSize()
        let effectiveUserProperties = await MainActor.run {
            try? WebWallpaperDesignService.shared.effectivePropertiesJSON(for: contentRoot.path)
        }
        let cacheURL = await MainActor.run {
            makeCacheURL(
                root: DownloadPathManager.shared.sceneBakesFolderURL,
                itemID: record.id,
                analysisId: analysisId,
                width: targetSize.width,
                height: targetSize.height,
                fps: Int(effectiveFPS),
                duration: effectiveDuration,
                userPropertiesJSON: effectiveUserProperties
            )
        }

        if let existing = SceneOfflineBakeService.usableArtifact(from: record),
           existing.renderer == .wallpaperEngineWeb,
           existing.videoPath == cacheURL.path {
            if let resumingJobID {
                await MainActor.run {
                    SceneOfflineBakeProgressTracker.shared.finish(
                        jobID: resumingJobID,
                        success: true
                    )
                }
            }
            return existing
        }

        let persistentJob = PersistentOfflineBakeJob.web(
            id: resumingJobID ?? UUID(),
            record: record,
            contentRoot: contentRoot,
            outputURL: cacheURL,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS
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
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                throw SceneOfflineBakeError.insufficientMemory
            }
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if let inspection = await inspectVideo(
                at: cacheURL,
                expectedWidth: targetSize.width,
                expectedHeight: targetSize.height
            ) {
                let bakedAt = fileCreationDate(for: cacheURL) ?? .now
                let artifact = SceneBakeArtifact(
                    analysisId: analysisId,
                    videoPath: cacheURL.path,
                    width: inspection.width,
                    height: inspection.height,
                    fps: Int(effectiveFPS),
                    durationSeconds: inspection.duration,
                    bakedAt: bakedAt,
                    renderer: .wallpaperEngineWeb
                )
                try await complete(
                    artifact: artifact,
                    record: record,
                    contentRoot: contentRoot,
                    jobID: jobID,
                    progress: trackedProgress
                )
                await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
                return artifact
            }

            try? FileManager.default.removeItem(at: cacheURL)
            let temporaryURL = cacheURL.deletingLastPathComponent()
                .appendingPathComponent(".\(cacheURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp.mp4")
            try? FileManager.default.removeItem(at: temporaryURL)

            var arguments = [
                "bake",
                contentRoot.path,
                "--size", "\(targetSize.width)x\(targetSize.height)",
                "--fps", String(effectiveFPS),
                "--duration", String(Int(effectiveDuration.rounded())),
                "--out", temporaryURL.path
            ]
            if let effectiveUserProperties,
               let data = effectiveUserProperties.data(using: .utf8) {
                arguments += ["--properties-base64", data.base64EncodedString()]
            }
            try await runCLI(
                executableURL: cli,
                arguments: arguments,
                progress: trackedProgress
            )

            guard let inspection = await inspectVideo(
                at: temporaryURL,
                expectedWidth: targetSize.width,
                expectedHeight: targetSize.height
            ) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw SceneOfflineBakeError.bakeProcessFailed("Web 烘焙完成后未找到有效 MP4")
            }

            try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
            let artifact = SceneBakeArtifact(
                analysisId: analysisId,
                videoPath: cacheURL.path,
                width: inspection.width,
                height: inspection.height,
                fps: Int(effectiveFPS),
                durationSeconds: inspection.duration,
                bakedAt: .now,
                renderer: .wallpaperEngineWeb
            )
            try await complete(
                artifact: artifact,
                record: record,
                contentRoot: contentRoot,
                jobID: jobID,
                progress: trackedProgress
            )
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            return artifact
        } catch {
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: false)
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            throw error
        }
    }

    @MainActor
    static func resumePersistedBakeJob(
        _ job: PersistentOfflineBakeJob
    ) async throws -> SceneBakeArtifact {
        guard job.kind == .web else {
            throw SceneOfflineBakeError.ineligible
        }
        let record = MediaLibraryService.shared.downloadedItems.first { record in
            record.id == job.recordID || record.item.id == job.itemID
        }
        guard let record else {
            SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                id: job.id,
                reason: "download record no longer exists"
            )
            throw SceneOfflineBakeError.contentRootMissing
        }
        return try await bake(
            record: record,
            durationSeconds: job.durationSeconds,
            fps: Int32(job.fps),
            resumingJobID: job.id
        )
    }

    static func scheduleAutoBakeAfterDownload(itemID: String, localFileURL: URL) {
        guard UserDefaults.standard.bool(forKey: "auto_bake_scene"),
              isWebProject(at: localFileURL) else {
            return
        }

        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let record = await MainActor.run {
                MediaLibraryService.shared.downloadRecord(for: itemID)
            }
            guard let record,
                  SceneOfflineBakeService.usableArtifact(from: record)?.renderer != .wallpaperEngineWeb else {
                return
            }
            do {
                _ = try await bake(record: record)
                print("[WebOfflineBake] auto-bake finished \(itemID)")
            } catch {
                print("[WebOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
            }
        }
    }

    private static func complete(
        artifact: SceneBakeArtifact,
        record: MediaDownloadRecord,
        contentRoot: URL,
        jobID: UUID,
        progress: (@MainActor (Double) -> Void)?
    ) async throws {
        await MainActor.run {
            MediaLibraryService.shared.attachSceneBakeArtifact(
                itemID: record.id,
                artifact: artifact,
                regeneratePoster: false
            )
        }
        await regenerateSceneBakePosterAndNotify(
            itemID: record.item.id,
            videoURL: URL(fileURLWithPath: artifact.videoPath)
        )
        await MainActor.run {
            progress?(1)
            SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: true)
            VideoOptimizationQueueService.shared.registerBakedSource(
                videoURL: URL(fileURLWithPath: artifact.videoPath),
                sourcePath: contentRoot.path,
                artifact: artifact
            )
            _ = VideoOptimizationQueueService.shared.enqueueAfterBakeIfNeeded(
                videoURL: URL(fileURLWithPath: artifact.videoPath),
                title: record.item.title
            )
            NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: artifact)
        }
    }

    private static func resolvedFPS(requested: Int32?) -> Int32 {
        let saved = UserDefaults.standard.double(forKey: "scene_bake_fps")
        let value = requested.map(Double.init) ?? (saved >= 15 ? saved : 30)
        return Int32(min(max(value, 15), maximumBakeFPS))
    }

    private static func resolvedDuration(requested: Double?) -> Double {
        if let requested {
            return min(max(requested, 5), 60)
        }
        let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
        return saved >= 5 ? min(max(saved, 5), 60) : 15
    }

    private static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 1
        let width = max(64, Int((frame.width * scale).rounded()))
        let height = max(64, Int((frame.height * scale).rounded()))
        return (width - (width % 2), height - (height % 2))
    }

    /// Same layout as `SceneOfflineBakeService.cacheVideoURL`.
    private static func makeCacheURL(
        root: URL,
        itemID: String,
        analysisId: UUID,
        width: Int,
        height: Int,
        fps: Int,
        duration: Double,
        userPropertiesJSON: String?
    ) -> URL {
        let safeItemID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = root.appendingPathComponent(safeItemID, isDirectory: true)
        let propertiesSuffix = propertiesCacheKey(for: userPropertiesJSON).map { "_props-\($0)" } ?? ""
        let name =
            "\(analysisId.uuidString)_\(SceneBakeRenderer.wallpaperEngineWeb.rawValue)_\(width)x\(height)_\(fps)fps_\(Int(duration.rounded()))s\(propertiesSuffix).mp4"
        return dir.appendingPathComponent(name)
    }

    /// Same as scene bake: empty properties → no suffix; otherwise SHA256 prefix.
    private static func propertiesCacheKey(for userPropertiesJSON: String?) -> String? {
        guard let userPropertiesJSON,
              !userPropertiesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let data: Data
        if let source = userPropertiesJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: source),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data = canonical
        } else {
            data = Data(userPropertiesJSON.utf8)
        }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileCreationDate(for url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date
    }

    private static func inspectVideo(
        at url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) async -> VideoInspection? {
        guard SceneOfflineBakeService.isUsableBakedVideo(at: url) else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else {
            return nil
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformed = naturalSize.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        let assetDuration = (try? await asset.load(.duration)) ?? .zero
        let duration = CMTimeGetSeconds(assetDuration)
        guard width == expectedWidth,
              height == expectedHeight,
              duration > 0.2 else {
            return nil
        }
        return VideoInspection(duration: duration, width: width, height: height)
    }

    private static func runCLI(
        executableURL: URL,
        arguments: [String],
        progress: (@MainActor (Double) -> Void)?
    ) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        final class StderrCapture: @unchecked Sendable {
            private let maxTailBytes = 128 * 1024
            var tail = Data()

            func append(_ data: Data) {
                tail.append(data)
                if tail.count > maxTailBytes {
                    tail.removeFirst(tail.count - maxTailBytes)
                }
            }
        }
        let capture = StderrCapture()

        let progressTask = Task.detached(priority: .utility) {
            var remainder = ""
            var lastProgress = 0.0
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                capture.append(data)
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                remainder += chunk
                let lines = remainder.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                remainder = lines.last ?? ""
                for line in lines.dropLast() {
                    guard let value = parseProgress(from: line) else { continue }
                    let clamped = min(max(value, lastProgress), 0.99)
                    guard clamped > lastProgress else { continue }
                    lastProgress = clamped
                    await progress?(clamped)
                }
            }
        }

        while process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await progressTask.value

        guard process.terminationStatus == 0 else {
            let tail = String(data: capture.tail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = tail.isEmpty
                ? "wallpaperengine-cli bake 执行失败 (exit=\(process.terminationStatus))"
                : "wallpaperengine-cli bake 执行失败 (exit=\(process.terminationStatus))\n\(tail)"
            throw SceneOfflineBakeError.bakeProcessFailed(message)
        }
    }

    private static func parseProgress(from line: String) -> Double? {
        guard line.contains("[web-bake]"),
              let percentStart = line.lastIndex(of: "["),
              let percentEnd = line[percentStart...].firstIndex(of: "%") else {
            return nil
        }
        let value = line[line.index(after: percentStart)..<percentEnd]
        return Double(value).map { $0 / 100 }
    }
}
