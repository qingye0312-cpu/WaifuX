import AVFoundation
import CoreVideo
import Foundation

#if DEBUG
private final class VideoLoopAnalysisTestHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceReplacementHook: (@Sendable () -> Void)?

    func setSourceReplacementHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        sourceReplacementHook = hook
        lock.unlock()
    }

    func runSourceReplacementHook() {
        lock.lock()
        let hook = sourceReplacementHook
        lock.unlock()
        hook?()
    }
}
#endif

private final class VideoLoopAnalysisExportCancellation: @unchecked Sendable {
    private let exportSession: AVAssetExportSession

    init(_ exportSession: AVAssetExportSession) {
        self.exportSession = exportSession
    }

    func cancel() {
        exportSession.cancelExport()
    }
}

/// Performs offline loop-point analysis for a single video.
///
/// The service deliberately has no knowledge of queues, wallpaper application,
/// library state, or UI. Callers own scheduling and record the returned outcome.
/// Its matching algorithm is the established low-resolution luminance pipeline:
/// a natural-loop preflight, whole-file candidate scan, 20-frame refinement, and
/// a `[start, end)` crop so the matching tail frame is excluded from the result.
enum VideoLoopAnalysisOutcome: Sendable, Equatable {
    case applied(firstContentFrame: Int, lastIncludedFrame: Int)
    case notNeeded
    case noReliablePoint
}

enum VideoLoopAnalysisService {
#if DEBUG
    private static let testHooks = VideoLoopAnalysisTestHooks()

    static func setSourceReplacementTestHook(_ hook: (@Sendable () -> Void)?) {
        testHooks.setSourceReplacementHook(hook)
    }
#endif

    static func analyzeAndReplace(
        videoURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoLoopAnalysisOutcome {
        try Task.checkCancellation()
        guard let outputContainer = VideoOptimizationOutputContainer(sourceURL: videoURL) else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey:
                    "In-place loop analysis supports MP4, MOV, and M4V only"]
            )
        }
        let temporaryURL = outputContainer.temporarySiblingURL(
            for: videoURL,
            operation: "loop-analysis"
        )

        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let decision = try await exportAnalyzedLoopVideo(
            from: videoURL,
            to: temporaryURL,
            outputContainer: outputContainer,
            progress: progress
        )

        switch decision {
        case .trim(let result):
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw NSError(
                    domain: "VideoLoopAnalysis",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Exported file not found"]
                )
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw CancellationError()
            }
            try VideoOptimizationFileReplacement.replaceSourceVideo(
                videoURL,
                with: temporaryURL
            )
#if DEBUG
            testHooks.runSourceReplacementHook()
#endif
            progress(1)
            return .applied(
                firstContentFrame: result.firstContentFrame,
                lastIncludedFrame: result.lastIncludedFrame
            )
        case .notNeeded:
            progress(1)
            return .notNeeded
        case .noReliablePoint:
            progress(1)
            return .noReliablePoint
        }
    }

    private struct LoopAnalysisResult: Sendable {
        let firstContentFrame: Int
        let lastIncludedFrame: Int
    }

    private enum LoopAnalysisDecision: Sendable {
        case trim(LoopAnalysisResult)
        case notNeeded
        case noReliablePoint
    }

    private struct TimedFrameSignature: Sendable {
        let frame: Int
        let time: CMTime
        let signature: FrameSignature
    }

    private struct RefinedLoopBoundary: Sendable {
        let candidateFrame: Int
        let start: TimedFrameSignature
        /// The first frame of the next loop. This frame is never exported.
        let loopFrame: TimedFrameSignature
        /// The final frame retained in the trimmed video.
        let lastIncludedFrame: TimedFrameSignature
        let difference: FrameWindowDifference
    }

    private static func exportAnalyzedLoopVideo(
        from originalURL: URL,
        to outputURL: URL,
        outputContainer: VideoOptimizationOutputContainer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoopAnalysisDecision {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: originalURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No video track"]
            )
        }

        progress(0.04)
        if try await isAlreadySeamlessLoop(asset: asset, videoTrack: videoTrack, duration: duration) {
            try Task.checkCancellation()
            progress(0.98)
            return .notNeeded
        }
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(videoOutput) else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read video frames"]
            )
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "VideoLoopAnalysis",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start video reader"]
            )
        }

        var referenceFrames: [TimedFrameSignature] = []
        var activeCandidates: [PendingLoopCandidate] = []
        var verifiedCandidates: [LoopCandidate] = []
        var pendingRefinements: [LoopCandidate] = []
        var refinedBoundaries: [RefinedLoopBoundary] = []
        var signatureWindow: [TimedFrameSignature] = []
        var frameIndex = 0
        let durationSeconds = max(0.001, duration.seconds)
        let verificationFrameCount = 12
        let refinementFrameCount = 20
        let signatureWindowCapacity = refinementFrameCount * 2 + 1
        let minimumLoopDuration: Double = 0.75

        // Decode once from the first non-black frame. A candidate needs 12
        // consecutive matching frames before it is eligible for refinement.
        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }
            let signature = try FrameSignature(pixelBuffer: pixelBuffer)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timedSignature = TimedFrameSignature(
                frame: frameIndex,
                time: presentationTime,
                signature: signature
            )
            if referenceFrames.isEmpty {
                if !signature.isPureBlack {
                    referenceFrames.append(timedSignature)
                    signatureWindow.append(timedSignature)
                }
            } else {
                signatureWindow.append(timedSignature)
                if signatureWindow.count > signatureWindowCapacity {
                    signatureWindow.removeFirst(signatureWindow.count - signatureWindowCapacity)
                }

                if referenceFrames.count < refinementFrameCount {
                    referenceFrames.append(timedSignature)
                } else if let startTime = referenceFrames.first?.time {
                    var remainingCandidates: [PendingLoopCandidate] = []
                    remainingCandidates.reserveCapacity(activeCandidates.count)

                    for var candidate in activeCandidates {
                        let referenceIndex = candidate.comparedFrameCount
                        candidate.append(signature, reference: referenceFrames[referenceIndex].signature)
                        if candidate.comparedFrameCount == verificationFrameCount {
                            if candidate.difference.isReliableLoopMatch {
                                let verifiedCandidate = candidate.completed()
                                verifiedCandidates.append(verifiedCandidate)
                                pendingRefinements.append(verifiedCandidate)
                            }
                        } else {
                            remainingCandidates.append(candidate)
                        }
                    }
                    activeCandidates = remainingCandidates

                    let elapsedFromStart = max(0, CMTimeGetSeconds(CMTimeSubtract(presentationTime, startTime)))
                    if elapsedFromStart >= minimumLoopDuration,
                       let previousFrame = signatureWindow.dropLast().last {
                        let difference = signature.difference(to: referenceFrames[0].signature)
                        if difference.isPotentialLoopMatch {
                            activeCandidates.append(PendingLoopCandidate(
                                frame: frameIndex,
                                time: presentationTime,
                                previousFrame: previousFrame,
                                firstDifference: difference
                            ))
                        }
                    }

                    refineReadyCandidates(
                        pendingRefinements: &pendingRefinements,
                        referenceFrames: referenceFrames,
                        signatureWindow: signatureWindow,
                        currentFrame: frameIndex,
                        isAtEnd: false,
                        refinedBoundaries: &refinedBoundaries
                    )
                }
            }

            if frameIndex % 12 == 0 {
                let elapsed = max(0, presentationTime.seconds)
                progress(0.05 + 0.60 * min(1, elapsed / durationSeconds))
            }
            frameIndex += 1
        }

        refineReadyCandidates(
            pendingRefinements: &pendingRefinements,
            referenceFrames: referenceFrames,
            signatureWindow: signatureWindow,
            currentFrame: frameIndex,
            isAtEnd: true,
            refinedBoundaries: &refinedBoundaries
        )
        try Task.checkCancellation()

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "VideoLoopAnalysis",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Video frame reading failed"]
            )
        }
        guard let firstReferenceFrame = referenceFrames.first else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No non-black frame found"]
            )
        }

        guard !verifiedCandidates.isEmpty else {
            // Only the full-pixel preflight may mark a video as already looped.
            // The analysis signatures are deliberately lossy, so their similarity
            // is not enough to skip a required crop.
            return .noReliablePoint
        }

        // Videos longer than ten seconds cannot crop to a short accidental
        // repetition. For short source clips, preserve the last candidate.
        let minimumAcceptedLoopDuration: Double = 10
        let candidatesForRefinement: [LoopCandidate]
        if durationSeconds <= minimumAcceptedLoopDuration {
            candidatesForRefinement = verifiedCandidates.max { lhs, rhs in
                CMTimeCompare(lhs.time, rhs.time) < 0
            }.map { [$0] } ?? []
        } else {
            candidatesForRefinement = verifiedCandidates.filter { candidate in
                CMTimeGetSeconds(CMTimeSubtract(candidate.time, firstReferenceFrame.time)) >= minimumAcceptedLoopDuration
            }
        }
        guard !candidatesForRefinement.isEmpty else {
            return .noReliablePoint
        }

        let candidateFrames = Set(candidatesForRefinement.map(\.frame))
        let fallbackCandidate = selectBestReliableCandidate(from: candidatesForRefinement)
        let bestRefinedBoundary = refinedBoundaries
            .filter { candidateFrames.contains($0.candidateFrame) }
            .min { lhs, rhs in
                if lhs.difference.qualityScore == rhs.difference.qualityScore {
                    return CMTimeCompare(lhs.loopFrame.time, rhs.loopFrame.time) > 0
                }
                return lhs.difference.qualityScore < rhs.difference.qualityScore
            }
        guard let selectedBoundary = bestRefinedBoundary ?? fallbackCandidate.map({
            RefinedLoopBoundary(
                candidateFrame: $0.frame,
                start: firstReferenceFrame,
                loopFrame: TimedFrameSignature(frame: $0.frame, time: $0.time, signature: firstReferenceFrame.signature),
                lastIncludedFrame: $0.previousFrame,
                difference: $0.difference
            )
        }),
        selectedBoundary.lastIncludedFrame.frame >= selectedBoundary.start.frame,
        selectedBoundary.loopFrame.frame == selectedBoundary.lastIncludedFrame.frame + 1,
        CMTimeCompare(selectedBoundary.loopFrame.time, selectedBoundary.lastIncludedFrame.time) > 0,
        CMTimeCompare(selectedBoundary.loopFrame.time, selectedBoundary.start.time) > 0 else {
            return .noReliablePoint
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try Task.checkCancellation()

        // AVFoundation time ranges are upper-bound exclusive. Ending exactly at
        // `loopFrame.time` keeps `lastIncludedFrame` and never writes the first
        // matching frame of the next loop into the exported asset.
        let sourceRange = CMTimeRange(
            start: selectedBoundary.start.time,
            duration: CMTimeSubtract(selectedBoundary.loopFrame.time, selectedBoundary.start.time)
        )
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 2)
        }
        try compositionVideoTrack.insertTimeRange(sourceRange, of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 4)
        }
        guard exportSession.supportedFileTypes.contains(outputContainer.fileType) else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 26,
                userInfo: [NSLocalizedDescriptionKey:
                    "Output container \(outputContainer.displayName) is not supported for this source"]
            )
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputContainer.fileType
        exportSession.shouldOptimizeForNetworkUse = false
        progress(0.78)

        let observation = exportSession.observe(\.progress, options: [.initial, .new]) { _, change in
            let exportProgress = min(1, max(0, Double(change.newValue ?? 0)))
            progress(0.78 + 0.21 * exportProgress)
        }
        defer { observation.invalidate() }
        let cancellation = VideoLoopAnalysisExportCancellation(exportSession)
        await withTaskCancellationHandler(operation: {
            await exportSession.export()
        }, onCancel: {
            cancellation.cancel()
        })
        try Task.checkCancellation()
        if let error = exportSession.error { throw error }
        guard exportSession.status == .completed else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Export status: \(exportSession.status.rawValue)"]
            )
        }

        progress(0.98)
        return .trim(LoopAnalysisResult(
            firstContentFrame: selectedBoundary.start.frame,
            lastIncludedFrame: selectedBoundary.lastIncludedFrame.frame
        ))
    }

    private static func makeLoopAnalysisVideoOutput(for videoTrack: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        return output
    }

    private static func isAlreadySeamlessLoop(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime
    ) async throws -> Bool {
        try Task.checkCancellation()
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds >= 1 else { return false }

        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = frameRate > 0 ? Double(frameRate) : 30
        let windowDurationSeconds = min(max(0.75, 42 / fps), durationSeconds * 0.25)
        let windowDuration = CMTime(seconds: windowDurationSeconds, preferredTimescale: 600_000)
        let tailStart = CMTimeMaximum(.zero, CMTimeSubtract(duration, windowDuration))
        guard let firstFrame = try readExactBoundaryFrame(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: .zero, duration: windowDuration),
            selectLastNonBlackFrame: false,
            matchingSampledLuma: nil
        ), let lastFrame = try readExactBoundaryFrame(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: tailStart, duration: CMTimeSubtract(duration, tailStart)),
            selectLastNonBlackFrame: true,
            matchingSampledLuma: firstFrame.signature
        ) else {
            return false
        }

        // Similar decoded frames still need a loop-point crop. Skip analysis
        // only when the full decoded image differs by codec-rounding noise.
        return firstFrame.visuallyMatches(lastFrame)
    }

    private static func readExactBoundaryFrame(
        from asset: AVAsset,
        videoTrack: AVAssetTrack,
        timeRange: CMTimeRange,
        selectLastNonBlackFrame: Bool,
        matchingSampledLuma: FrameSignature?
    ) throws -> ExactFramePixels? {
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 18)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 19)
        }

        var selectedFrame: ExactFramePixels?
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let signature = try FrameSignature(pixelBuffer: pixelBuffer)
            guard !signature.isPureBlack else { continue }

            if let matchingSampledLuma,
               !signature.isNearIdenticalSampledLuma(to: matchingSampledLuma) {
                if selectLastNonBlackFrame {
                    selectedFrame = nil
                }
                continue
            }

            let exactFrame = try ExactFramePixels(pixelBuffer: pixelBuffer, signature: signature)
            if !selectLastNonBlackFrame {
                if reader.status == .reading { reader.cancelReading() }
                return exactFrame
            }
            selectedFrame = exactFrame
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 20)
        }
        if reader.status == .reading { reader.cancelReading() }
        return selectedFrame
    }

    /// Refines every verified candidate from the 41-frame signature window
    /// collected during the primary decode. Reopening an AVAssetReader for each
    /// candidate made visually static videos disproportionately slow.
    private static func refineReadyCandidates(
        pendingRefinements: inout [LoopCandidate],
        referenceFrames: [TimedFrameSignature],
        signatureWindow: [TimedFrameSignature],
        currentFrame: Int,
        isAtEnd: Bool,
        refinedBoundaries: inout [RefinedLoopBoundary]
    ) {
        let localFrameCount = min(20, referenceFrames.count)
        guard localFrameCount >= 5 else { return }

        while let candidate = pendingRefinements.first,
              isAtEnd || currentFrame >= candidate.frame + localFrameCount {
            pendingRefinements.removeFirst()
            let lowerBound = candidate.frame - localFrameCount
            let upperBound = candidate.frame + localFrameCount
            let candidateFrames = signatureWindow.filter {
                $0.frame >= lowerBound && $0.frame <= upperBound
            }
            if let refinedBoundary = refineLoopBoundary(
                referenceFrames: referenceFrames,
                candidateFrames: candidateFrames,
                candidate: candidate
            ) {
                refinedBoundaries.append(refinedBoundary)
            }
        }
    }

    private static func refineLoopBoundary(
        referenceFrames: [TimedFrameSignature],
        candidateFrames: [TimedFrameSignature],
        candidate: LoopCandidate
    ) -> RefinedLoopBoundary? {
        let localFrameCount = min(20, referenceFrames.count)
        let starts = Array(referenceFrames.prefix(localFrameCount))
        guard starts.count >= 5 else { return nil }

        let gpuDifferences = VideoLoopAnalysisMetalComparator.shared.pairwiseDifferences(
            referenceSignatures: starts.map(\.signature.luma),
            candidateSignatures: candidateFrames.map(\.signature.luma)
        )
        let cpuDifferences: [FrameDifference]?
        if gpuDifferences == nil {
            cpuDifferences = starts.flatMap { start in
                candidateFrames.map { candidateFrame in
                    start.signature.difference(to: candidateFrame.signature)
                }
            }
        } else {
            cpuDifferences = nil
        }
        let validationFrameCount = 5
        var bestBoundary: RefinedLoopBoundary?
        var bestScore = Double.greatestFiniteMagnitude
        for startIndex in starts.indices {
            for loopIndex in candidateFrames.indices {
                guard loopIndex > candidateFrames.startIndex else { continue }
                let availableFrames = min(starts.count - startIndex, candidateFrames.count - loopIndex)
                guard availableFrames >= validationFrameCount,
                      CMTimeCompare(candidateFrames[loopIndex].time, starts[startIndex].time) > 0 else {
                    continue
                }
                var difference = FrameWindowDifference()
                for offset in 0..<validationFrameCount {
                    let referenceIndex = startIndex + offset
                    let candidateIndex = loopIndex + offset
                    if let gpuDifferences {
                        difference.append(FrameDifference(
                            gpuDifferences[referenceIndex * candidateFrames.count + candidateIndex]
                        ))
                    } else if let cpuDifferences {
                        difference.append(
                            cpuDifferences[referenceIndex * candidateFrames.count + candidateIndex]
                        )
                    }
                }
                guard difference.isVisuallyReliableLoopMatch else { continue }
                // The verified candidate only bounds the refinement window.
                // Keep every pairing here so the closest two real frames choose
                // both the output start and the first excluded loop frame.
                let score = difference.qualityScore + Double(abs(startIndex - loopIndex)) * 0.015
                if score < bestScore {
                    bestScore = score
                    bestBoundary = RefinedLoopBoundary(
                        candidateFrame: candidate.frame,
                        start: starts[startIndex],
                        loopFrame: candidateFrames[loopIndex],
                        lastIncludedFrame: candidateFrames[loopIndex - 1],
                        difference: difference
                    )
                }
            }
        }
        return bestBoundary
    }

    private struct FrameWindowDifference: Sendable {
        private(set) var absoluteDifferenceTotal = 0
        private(set) var squaredDifferenceTotal = 0
        private(set) var strongDifferenceCount = 0
        private(set) var sampleCount = 0

        init() {}

        init(_ difference: FrameDifference) { append(difference) }

        mutating func append(_ difference: FrameDifference) {
            absoluteDifferenceTotal += difference.absoluteDifferenceTotal
            squaredDifferenceTotal += difference.squaredDifferenceTotal
            strongDifferenceCount += difference.strongDifferenceCount
            sampleCount += difference.sampleCount
        }

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        var isReliableLoopMatch: Bool {
            meanAbsoluteDifference <= 7
                && rootMeanSquareDifference <= 16
                && strongDifferenceRatio <= 0.05
        }

        /// The final crop boundary may tolerate a little decoded-video noise
        /// after the strict 12-frame candidate gate. Every accepted boundary is
        /// still ranked against all verified candidates by `qualityScore`.
        var isVisuallyReliableLoopMatch: Bool {
            meanAbsoluteDifference <= 9
                && rootMeanSquareDifference <= 20
                && strongDifferenceRatio <= 0.08
        }

        var qualityScore: Double {
            meanAbsoluteDifference / 7
                + rootMeanSquareDifference / 16
                + strongDifferenceRatio / 0.05
        }
    }

    private struct FrameDifference: Sendable {
        let absoluteDifferenceTotal: Int
        let squaredDifferenceTotal: Int
        let strongDifferenceCount: Int
        let sampleCount: Int

        init(
            absoluteDifferenceTotal: Int,
            squaredDifferenceTotal: Int,
            strongDifferenceCount: Int,
            sampleCount: Int
        ) {
            self.absoluteDifferenceTotal = absoluteDifferenceTotal
            self.squaredDifferenceTotal = squaredDifferenceTotal
            self.strongDifferenceCount = strongDifferenceCount
            self.sampleCount = sampleCount
        }

        init(_ metrics: VideoLoopAnalysisDifferenceMetrics) {
            absoluteDifferenceTotal = metrics.absoluteDifferenceTotal
            squaredDifferenceTotal = metrics.squaredDifferenceTotal
            strongDifferenceCount = metrics.strongDifferenceCount
            sampleCount = metrics.sampleCount
        }

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        var isPotentialLoopMatch: Bool {
            meanAbsoluteDifference <= 11
                && rootMeanSquareDifference <= 28
                && strongDifferenceRatio <= 0.12
        }
    }

    private struct PendingLoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        let previousFrame: TimedFrameSignature
        private(set) var comparedFrameCount = 1
        private(set) var difference: FrameWindowDifference

        init(
            frame: Int,
            time: CMTime,
            previousFrame: TimedFrameSignature,
            firstDifference: FrameDifference
        ) {
            self.frame = frame
            self.time = time
            self.previousFrame = previousFrame
            difference = FrameWindowDifference(firstDifference)
        }

        mutating func append(_ signature: FrameSignature, reference: FrameSignature) {
            difference.append(signature.difference(to: reference))
            comparedFrameCount += 1
        }

        func completed() -> LoopCandidate {
            LoopCandidate(
                frame: frame,
                time: time,
                previousFrame: previousFrame,
                difference: difference
            )
        }
    }

    private struct LoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        let previousFrame: TimedFrameSignature
        let difference: FrameWindowDifference
    }

    private struct ExactFramePixels: Sendable {
        let signature: FrameSignature
        let pixelFormat: OSType
        let width: Int
        let height: Int
        let planes: [Data]

        init(pixelBuffer: CVPixelBuffer, signature: FrameSignature) throws {
            self.signature = signature
            pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else {
                throw NSError(domain: "VideoLoopAnalysis", code: 21)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 22)
                }
                planes = try (0..<2).map { planeIndex in
                    try Self.copyPlane(
                        from: pixelBuffer,
                        index: planeIndex,
                        bytesPerSample: planeIndex == 0 ? 1 : 2
                    )
                }
            case kCVPixelFormatType_32BGRA:
                guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 23)
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                planes = [Self.copyRows(
                    baseAddress: baseAddress,
                    bytesPerRow: bytesPerRow,
                    rowByteCount: min(bytesPerRow, width * 4),
                    height: height
                )]
            default:
                throw NSError(
                    domain: "VideoLoopAnalysis",
                    code: 24,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported video pixel format: \(pixelFormat)"]
                )
            }
        }

        /// Treat only codec-rounding noise as an already seamless loop. This
        /// deliberately remains much stricter than the visual candidate score
        /// used for selecting a crop boundary.
        func visuallyMatches(_ other: ExactFramePixels) -> Bool {
            guard pixelFormat == other.pixelFormat,
                  width == other.width,
                  height == other.height,
                  planes.count == other.planes.count else {
                return false
            }

            if planes.count == 1 {
                return Self.matchesWithinCodecTolerance(
                    planes[0],
                    other.planes[0],
                    maximumMeanDifference: 0.35,
                    toleratedDifference: 2,
                    maximumDifference: 4
                )
            }

            return Self.matchesWithinCodecTolerance(
                planes[0],
                other.planes[0],
                maximumMeanDifference: 0.35,
                toleratedDifference: 2,
                maximumDifference: 4
            ) && Self.matchesWithinCodecTolerance(
                planes[1],
                other.planes[1],
                maximumMeanDifference: 0.5,
                toleratedDifference: 3,
                maximumDifference: 5
            )
        }

        private static func matchesWithinCodecTolerance(
            _ lhs: Data,
            _ rhs: Data,
            maximumMeanDifference: Double,
            toleratedDifference: Int,
            maximumDifference: Int
        ) -> Bool {
            guard lhs.count == rhs.count, !lhs.isEmpty else { return false }

            var absoluteDifferenceTotal = 0
            var outlierCount = 0
            var observedMaximumDifference = 0
            for (left, right) in zip(lhs, rhs) {
                let difference = abs(Int(left) - Int(right))
                absoluteDifferenceTotal += difference
                observedMaximumDifference = max(observedMaximumDifference, difference)
                if difference > toleratedDifference {
                    outlierCount += 1
                }
            }

            let meanDifference = Double(absoluteDifferenceTotal) / Double(lhs.count)
            let outlierRatio = Double(outlierCount) / Double(lhs.count)
            return meanDifference <= maximumMeanDifference
                && observedMaximumDifference <= maximumDifference
                && outlierRatio <= 0.0005
        }

        private static func copyPlane(
            from pixelBuffer: CVPixelBuffer,
            index: Int,
            bytesPerSample: Int
        ) throws -> Data {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            guard width > 0, height > 0,
                  let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index) else {
                throw NSError(domain: "VideoLoopAnalysis", code: 24)
            }
            return copyRows(
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow,
                rowByteCount: min(bytesPerRow, width * bytesPerSample),
                height: height
            )
        }

        private static func copyRows(
            baseAddress: UnsafeMutableRawPointer,
            bytesPerRow: Int,
            rowByteCount: Int,
            height: Int
        ) -> Data {
            var data = Data()
            data.reserveCapacity(rowByteCount * height)
            for rowIndex in 0..<height {
                let row = baseAddress.advanced(by: rowIndex * bytesPerRow)
                data.append(contentsOf: UnsafeRawBufferPointer(start: row, count: rowByteCount))
            }
            return data
        }
    }

    private static func selectBestReliableCandidate(from candidates: [LoopCandidate]) -> LoopCandidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            if lhs.difference.qualityScore == rhs.difference.qualityScore {
                return CMTimeCompare(lhs.time, rhs.time) > 0
            }
            return lhs.difference.qualityScore < rhs.difference.qualityScore
        }
    }

    private struct FrameSignature: Sendable {
        let luma: [UInt8]
        let averageLuma: Double

        init(pixelBuffer: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let sampleWidth = 96
            let sampleHeight = 54
            var sampledLuma = [UInt8]()
            sampledLuma.reserveCapacity(sampleWidth * sampleHeight)
            var sum = 0

            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                guard width > 0, height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 13)
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let value = row[sourceX]
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            case kCVPixelFormatType_32BGRA:
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                guard width > 0, height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 14)
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let pixel = row.advanced(by: sourceX * 4)
                        let blue = Int(pixel[2])
                        let green = Int(pixel[1])
                        let red = Int(pixel[0])
                        let luminance = 77 * blue + 150 * green + 29 * red + 128
                        let value = UInt8(luminance >> 8)
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            default:
                throw NSError(
                    domain: "VideoLoopAnalysis",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported video pixel format: \(pixelFormat)"]
                )
            }
            luma = sampledLuma
            averageLuma = Double(sum) / Double(max(1, sampledLuma.count))
        }

        var isPureBlack: Bool { averageLuma <= 3 }

        func difference(to other: FrameSignature) -> FrameDifference {
            guard luma.count == other.luma.count else {
                return FrameDifference(
                    absoluteDifferenceTotal: .max / 4,
                    squaredDifferenceTotal: .max / 4,
                    strongDifferenceCount: .max / 4,
                    sampleCount: 1
                )
            }
            var absoluteDifferenceTotal = 0
            var squaredDifferenceTotal = 0
            var strongDifferenceCount = 0
            for index in luma.indices {
                let delta = abs(Int(luma[index]) - Int(other.luma[index]))
                absoluteDifferenceTotal += delta
                squaredDifferenceTotal += delta * delta
                if delta > 36 { strongDifferenceCount += 1 }
            }
            return FrameDifference(
                absoluteDifferenceTotal: absoluteDifferenceTotal,
                squaredDifferenceTotal: squaredDifferenceTotal,
                strongDifferenceCount: strongDifferenceCount,
                sampleCount: luma.count
            )
        }

        func isNearIdenticalSampledLuma(to other: FrameSignature) -> Bool {
            guard luma.count == other.luma.count, !luma.isEmpty else { return false }

            var absoluteDifferenceTotal = 0
            var largeDifferenceCount = 0
            var maximumDifference = 0
            for index in luma.indices {
                let difference = abs(Int(luma[index]) - Int(other.luma[index]))
                absoluteDifferenceTotal += difference
                maximumDifference = max(maximumDifference, difference)
                if difference > 1 {
                    largeDifferenceCount += 1
                }
            }

            let meanDifference = Double(absoluteDifferenceTotal) / Double(luma.count)
            let largeDifferenceRatio = Double(largeDifferenceCount) / Double(luma.count)
            return meanDifference <= 0.35
                && maximumDifference <= 3
                && largeDifferenceRatio <= 0.005
        }
    }
}
