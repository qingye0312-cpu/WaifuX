import Foundation
import Combine

// MARK: - WE Web 壁纸 Media Integration 中继
//
// 订阅 NowPlayingService，把系统正在播放推给 wallpaperengine-cli daemon：
//   mediaUpdate   → status / properties / playback / timeline
//   mediaThumbnail → 封面 data URL（换歌才发，payload 大）
//   mediaLyrics / mediaLyricsLine → Apple Music 歌词（Host 鉴权，Web 只收推送）
//
// 与 WallpaperWebAudioRelay 并列：音频走 spectrum；媒体元数据走本类。
// Web 页只收推送，不碰 token。

@MainActor
public final class WallpaperWebMediaRelay {

    public static let shared = WallpaperWebMediaRelay()

    private var referenceCount = 0
    private var cancellable: AnyCancellable?
    private var lyricsDocCancellable: AnyCancellable?
    private var lyricsLineCancellable: AnyCancellable?
    private var timelineTimer: Timer?

    private var lastTitle = ""
    private var lastArtist = ""
    private var lastAlbum = ""
    private var lastPlaying: Bool?
    private var lastEnabled: Bool?
    private var lastArtworkHash = 0
    private var lastTimelinePushAt: Date = .distantPast
    private var lastLyricsSongId = ""
    private var lastLyricsLineIndex: Int = Int.min

    /// timeline 推送最小间隔（秒）
    private let timelineMinInterval: TimeInterval = 0.9

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        referenceCount += 1
        guard referenceCount == 1 else { return }

        NowPlayingService.shared.start()
        AppleMusicLyricsService.shared.start()

        cancellable = NowPlayingService.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.handle(snap)
            }

        lyricsDocCancellable = AppleMusicLyricsService.shared.$currentDoc
            .receive(on: DispatchQueue.main)
            .sink { [weak self] doc in
                self?.pushLyricsDoc(doc)
            }

        lyricsLineCancellable = AppleMusicLyricsService.shared.$currentLine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                self?.pushLyricsLine(line)
            }

        // 进度本地外推：即使 snapshot 未变也低频刷 timeline + 歌词行
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onTimerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timelineTimer = timer

        // 立即推当前状态
        handle(NowPlayingService.shared.snapshot)
        print("[WallpaperWebMediaRelay] started")
    }

    public func stop() {
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        guard referenceCount == 0 else { return }

        cancellable?.cancel()
        cancellable = nil
        lyricsDocCancellable?.cancel()
        lyricsDocCancellable = nil
        lyricsLineCancellable?.cancel()
        lyricsLineCancellable = nil
        timelineTimer?.invalidate()
        timelineTimer = nil
        AppleMusicLyricsService.shared.stop()
        NowPlayingService.shared.stop()

        // 清空媒体，让壁纸 mediaPlaying 回落
        pushEmpty()
        pushLyricsDoc(nil)
        resetDedupe()
        print("[WallpaperWebMediaRelay] stopped")
    }

    /// 换壁纸后强制重推（不重置 refcount）
    public func forcePush() {
        resetDedupe()
        NowPlayingService.shared.refresh()
        handle(NowPlayingService.shared.snapshot)
        pushLyricsDoc(AppleMusicLyricsService.shared.currentDoc)
        pushLyricsLine(AppleMusicLyricsService.shared.currentLine, force: true)
    }

    // MARK: - Push

    private func handle(_ snap: NowPlayingSnapshot) {
        let enabled = snap.hasMedia
        let title = snap.title
        let artist = snap.artist
        let album = snap.album
        let playing = snap.isPlaying

        let propsChanged = title != lastTitle || artist != lastArtist || album != lastAlbum
        let playChanged = lastPlaying.map { $0 != playing } ?? true
        let enabledChanged = lastEnabled.map { $0 != enabled } ?? true

        if enabledChanged || propsChanged || playChanged {
            let state: Int
            if !enabled {
                state = 0 // STOPPED
            } else if playing {
                state = 1 // PLAYING
            } else {
                state = 2 // PAUSED
            }

            let elapsed = NowPlayingService.shared.estimatedElapsed
            print("[WallpaperWebMediaRelay] push mediaUpdate enabled=\(enabled) title=\(enabled ? title : "") state=\(state)")
            WallpaperEngineXBridge.shared.sendMediaUpdateToWebDaemon(
                enabled: enabled,
                title: enabled ? title : "",
                artist: enabled ? artist : "",
                albumTitle: enabled ? album : "",
                state: state,
                position: enabled ? elapsed : 0,
                duration: enabled ? snap.duration : 0,
                rate: snap.rate > 0 ? snap.rate : 1
            )

            lastTitle = title
            lastArtist = artist
            lastAlbum = album
            lastPlaying = playing
            lastEnabled = enabled
            lastTimelinePushAt = Date()
        }

        // 封面：hash 变了才推
        if enabled, snap.artworkHash != 0, snap.artworkHash != lastArtworkHash,
           let data = snap.artworkData,
           let dataURL = NowPlayingThumbnail.jpegDataURL(from: data) {
            WallpaperEngineXBridge.shared.sendMediaThumbnailToWebDaemon(dataURL: dataURL)
            lastArtworkHash = snap.artworkHash
        } else if !enabled, lastArtworkHash != 0 {
            WallpaperEngineXBridge.shared.sendMediaThumbnailToWebDaemon(dataURL: "")
            lastArtworkHash = 0
        } else if enabled, snap.artworkData == nil, lastArtworkHash != 0 {
            WallpaperEngineXBridge.shared.sendMediaThumbnailToWebDaemon(dataURL: "")
            lastArtworkHash = 0
        }

        // 歌词：换歌触发拉；进度由 timer tick
        if enabled {
            if propsChanged || enabledChanged {
                AppleMusicLyricsService.shared.onTrackChanged(title: title, artist: artist)
            }
            AppleMusicLyricsService.shared.tick(
                elapsed: NowPlayingService.shared.estimatedElapsed,
                isPlaying: playing
            )
        } else if enabledChanged {
            AppleMusicLyricsService.shared.onTrackChanged(title: "", artist: "")
        }

        // 仅进度变化时走 timeline 路径
        if enabled, !propsChanged, !playChanged {
            pushTimelineIfNeeded()
        }
    }

    private func onTimerTick() {
        guard lastEnabled == true else { return }
        let snap = NowPlayingService.shared.snapshot
        guard snap.hasMedia else { return }
        AppleMusicLyricsService.shared.tick(
            elapsed: NowPlayingService.shared.estimatedElapsed,
            isPlaying: snap.isPlaying
        )
        pushTimelineIfNeeded()
    }

    private func pushTimelineIfNeeded() {
        guard lastEnabled == true else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTimelinePushAt) >= timelineMinInterval else { return }
        lastTimelinePushAt = now

        let snap = NowPlayingService.shared.snapshot
        guard snap.hasMedia else { return }
        let elapsed = NowPlayingService.shared.estimatedElapsed
        let state = snap.isPlaying ? 1 : 2
        WallpaperEngineXBridge.shared.sendMediaUpdateToWebDaemon(
            enabled: true,
            title: snap.title,
            artist: snap.artist,
            albumTitle: snap.album,
            state: state,
            position: elapsed,
            duration: snap.duration,
            rate: snap.rate > 0 ? snap.rate : 1
        )
    }

    private func pushEmpty() {
        WallpaperEngineXBridge.shared.sendMediaUpdateToWebDaemon(
            enabled: false,
            title: "",
            artist: "",
            albumTitle: "",
            state: 0,
            position: 0,
            duration: 0,
            rate: 1
        )
        WallpaperEngineXBridge.shared.sendMediaThumbnailToWebDaemon(dataURL: "")
    }

    private func pushLyricsDoc(_ doc: LyricsDoc?) {
        if let doc, doc.hasLyrics {
            if doc.songId == lastLyricsSongId, !lastLyricsSongId.isEmpty { return }
            lastLyricsSongId = doc.songId
            lastLyricsLineIndex = Int.min
            print("[WallpaperWebMediaRelay] push mediaLyrics songId=\(doc.songId) lines=\(doc.lines.count)")
            WallpaperEngineXBridge.shared.sendMediaLyricsToWebDaemon(
                hasLyrics: true,
                title: doc.title,
                artist: doc.artist,
                songId: doc.songId,
                storefront: doc.storefront,
                source: doc.source,
                lines: doc.lines.map { (start: $0.start, end: $0.end, text: $0.text) }
            )
        } else {
            if lastLyricsSongId.isEmpty && AppleMusicLyricsService.shared.currentDoc == nil {
                // 已空：仍推一次清空（force 场景）
            }
            lastLyricsSongId = ""
            lastLyricsLineIndex = Int.min
            WallpaperEngineXBridge.shared.sendMediaLyricsToWebDaemon(
                hasLyrics: false,
                title: "",
                artist: "",
                songId: "",
                storefront: "",
                source: "",
                lines: []
            )
        }
    }

    private func pushLyricsLine(_ line: LyricsLineState, force: Bool = false) {
        if !force, line.index == lastLyricsLineIndex { return }
        // 无歌词文档时不刷空行（避免噪声）；force 或 hasLine/index 变化才推
        if AppleMusicLyricsService.shared.currentDoc == nil, !line.hasLine, line.index < 0, !force {
            return
        }
        lastLyricsLineIndex = line.index
        WallpaperEngineXBridge.shared.sendMediaLyricsLineToWebDaemon(
            index: line.index,
            text: line.text,
            nextText: line.nextText,
            previousText: line.previousText,
            start: line.start,
            end: line.end,
            progress: line.progress,
            elapsedTime: line.elapsedTime,
            hasLine: line.hasLine
        )
    }

    private func resetDedupe() {
        lastTitle = ""
        lastArtist = ""
        lastAlbum = ""
        lastPlaying = nil
        lastEnabled = nil
        lastArtworkHash = 0
        lastTimelinePushAt = .distantPast
        lastLyricsSongId = ""
        lastLyricsLineIndex = Int.min
    }
}
