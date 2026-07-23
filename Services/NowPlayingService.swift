import Foundation
import AppKit
import Combine
import Darwin
import MusicKit

// MARK: - System Now Playing (MediaRemote + AppleScript fallback)
//
// Host 侧读取 macOS「正在播放」：title / artist / album / artwork / progress。
// 不涉及 Apple Music token；Web 壁纸只通过 bridge 收推送。
//
// 数据源优先级：
//   1. MediaRemote（dlopen 私有框架）— 全源统一；在部分签名/TCC 下会
//      kMRMediaRemoteFrameworkErrorDomain Code=3 Operation not permitted
//   2. Music.app / Spotify AppleScript — 当 MediaRemote 连续失败时启用
//   3. DistributedNotificationCenter（Music playerInfo）— 切歌即时
//
// 回调纪律：MediaRemote block 内禁止嵌套 Task { @MainActor }。

/// 系统当前媒体快照（给 Web Media Integration 用）
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var elapsed: Double
    public var duration: Double
    public var rate: Double
    /// 原始封面字节（JPEG/PNG 等）
    public var artworkData: Data?
    /// 封面内容 hash，用于避免重复推送
    public var artworkHash: Int

    public var hasMedia: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let empty = NowPlayingSnapshot(
        title: "",
        artist: "",
        album: "",
        isPlaying: false,
        elapsed: 0,
        duration: 0,
        rate: 1,
        artworkData: nil,
        artworkHash: 0
    )
}

@MainActor
public final class NowPlayingService: ObservableObject {

    public static let shared = NowPlayingService()

    @Published public private(set) var snapshot: NowPlayingSnapshot = .empty

    /// 带本地外推的播放进度（秒）
    public var estimatedElapsed: Double {
        guard snapshot.hasMedia else { return 0 }
        guard snapshot.isPlaying, anchorPlaying else { return max(0, anchorBase) }
        let dt = Date().timeIntervalSince(anchorAt) * max(0, anchorRate)
        let value = anchorBase + dt
        if snapshot.duration > 0 {
            return min(max(0, value), snapshot.duration)
        }
        return max(0, value)
    }

    private var referenceCount = 0
    private var pollTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var mediaRemoteAvailable = false
    private var mediaRemoteHandle: UnsafeMutableRawPointer?

    // Elapsed anchor
    private var anchorBase: Double = 0
    private var anchorAt: Date = .distantPast
    private var anchorPlaying = false
    private var anchorRate: Double = 1

    private var lastInfoIdentity: String = ""
    private var consecutiveEmptyFetches = 0
    private let emptyClearThreshold = 3

    /// MediaRemote 连续拿不到有效媒体 → 切到 AppleScript 回退
    private var mediaRemoteMisses = 0
    private let mediaRemoteMissThreshold = 2
    private var preferScriptFallback = false
    private var musicAuthRequested = false

    /// MediaRemote 并行回调合并缓冲（非 MainActor，避免 Swift 6 隔离报错）
    private let mediaFetchState = MediaRemoteFetchState()

    private var keyTitle: String = "kMRMediaRemoteNowPlayingInfoTitle"
    private var keyArtist: String = "kMRMediaRemoteNowPlayingInfoArtist"
    private var keyAlbum: String = "kMRMediaRemoteNowPlayingInfoAlbum"
    private var keyDuration: String = "kMRMediaRemoteNowPlayingInfoDuration"
    private var keyElapsed: String = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    private var keyRate: String = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    private var keyArtwork: String = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private var notifInfoChanged: String = "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
    private var notifPlayingChanged: String = "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
    private var notifAppChanged: String = "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"

    private var registerForNotifications: (@convention(c) (DispatchQueue) -> Void)?
    private var getNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void)?
    private var getIsPlaying: (@convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void)?

    private let mediaQueue = DispatchQueue(label: "com.waifux.nowplaying.mediaremote", qos: .userInitiated)
    private let scriptQueue = DispatchQueue(label: "com.waifux.nowplaying.applescript", qos: .utility)

    private init() {
        mediaRemoteAvailable = loadMediaRemote()
    }

    // MARK: - Lifecycle

    public func start() {
        referenceCount += 1
        guard referenceCount == 1 else { return }

        requestMusicAuthorizationIfNeeded()
        if mediaRemoteAvailable {
            registerNotifications()
        }
        registerDistributedPlayerNotifications()
        startPolling()
        refresh()
        print("[NowPlayingService] started mr=\(mediaRemoteAvailable) musicAuth=\(MusicAuthorization.currentStatus)")
    }

    public func stop() {
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        guard referenceCount == 0 else { return }
        stopPolling()
        unregisterNotifications()
        unregisterDistributedPlayerNotifications()
        consecutiveEmptyFetches = 0
        mediaRemoteMisses = 0
        preferScriptFallback = false
        apply(.empty)
        print("[NowPlayingService] stopped")
    }

    public func refresh() {
        fetchNowPlaying()
    }

    // MARK: - MusicKit authorization (helps MediaRemote + declares intent)

    private func requestMusicAuthorizationIfNeeded() {
        guard !musicAuthRequested else { return }
        musicAuthRequested = true
        let status = MusicAuthorization.currentStatus
        guard status == .notDetermined else {
            print("[NowPlayingService] MusicAuthorization status=\(status)")
            return
        }
        Task { @MainActor in
            let result = await MusicAuthorization.request()
            print("[NowPlayingService] MusicAuthorization request → \(result)")
            // 授权变化后立刻再拉一次
            self.fetchNowPlaying()
        }
    }

    // MARK: - MediaRemote load

    private func loadMediaRemote() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            print("[NowPlayingService] dlopen MediaRemote failed")
            return false
        }
        mediaRemoteHandle = handle

        typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
        typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
        typealias GetPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

        guard
            let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications"),
            let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
            let playSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        else {
            print("[NowPlayingService] dlsym MediaRemote symbols failed")
            return false
        }

        registerForNotifications = unsafeBitCast(regSym, to: RegisterFn.self)
        getNowPlayingInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)
        getIsPlaying = unsafeBitCast(playSym, to: GetPlayingFn.self)

        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoTitle") { keyTitle = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoArtist") { keyArtist = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoAlbum") { keyAlbum = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoDuration") { keyDuration = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoElapsedTime") { keyElapsed = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoPlaybackRate") { keyRate = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoArtworkData") { keyArtwork = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification") { notifInfoChanged = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification") { notifPlayingChanged = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification") { notifAppChanged = s }

        print("[NowPlayingService] MediaRemote loaded keys title=\(keyTitle)")
        return true
    }

    private static func cfStringConstant(_ handle: UnsafeMutableRawPointer, _ symbol: String) -> String? {
        guard let sym = dlsym(handle, symbol) else { return nil }
        let cf = sym.assumingMemoryBound(to: CFString?.self).pointee
        guard let cf else { return nil }
        return cf as String
    }

    private func registerNotifications() {
        registerForNotifications?(mediaQueue)
        let names = [notifInfoChanged, notifPlayingChanged, notifAppChanged]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.fetchNowPlaying() }
            }
            notificationTokens.append(token)
        }
    }

    private func unregisterNotifications() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func registerDistributedPlayerNotifications() {
        let names = [
            "com.apple.Music.playerInfo",
            "com.apple.iTunes.playerInfo",
            "com.spotify.client.PlaybackStateChanged",
        ]
        let center = DistributedNotificationCenter.default()
        for name in names {
            let token = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: nil
            ) { [weak self] note in
                // 只提取可 Sendable 的标量，避免 Swift 6 把 note.userInfo 送进 MainActor
                let payload = DistributedPlayerPayload(userInfo: note.userInfo)
                DispatchQueue.main.async {
                    self?.handleDistributedPlayerPayload(name: name, payload: payload)
                }
            }
            distributedTokens.append(token)
        }
    }

    private func unregisterDistributedPlayerNotifications() {
        let center = DistributedNotificationCenter.default()
        for token in distributedTokens {
            center.removeObserver(token)
        }
        distributedTokens.removeAll()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.fetchNowPlaying() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Fetch orchestration

    private func fetchNowPlaying() {
        // 已确认 MediaRemote 不可用 / 连续 miss：主路径走脚本
        if preferScriptFallback || !mediaRemoteAvailable {
            fetchViaAppleScript()
            return
        }
        fetchViaMediaRemote()
        // 并行拉一次脚本：若 MR 被拒，脚本仍能立刻填上，避免黑屏等待
        if mediaRemoteMisses >= 1 || snapshot.hasMedia == false {
            fetchViaAppleScript()
        }
    }

    // MARK: - MediaRemote

    private func fetchViaMediaRemote() {
        guard let getInfo = getNowPlayingInfo else { return }
        let getPlaying = getIsPlaying
        let state = mediaFetchState
        let generation = state.beginFetch()

        getInfo(mediaQueue) { [weak self] info in
            guard let self else { return }
            let retained = info.map { NSDictionary(dictionary: $0) }
            guard let merged = state.noteInfo(retained, generation: generation, playingOptional: getPlaying == nil) else {
                return
            }
            DispatchQueue.main.async {
                self.consumeMediaRemote(info: merged.info, isPlaying: merged.playing, generation: generation)
            }
        }

        if let getPlaying {
            getPlaying(mediaQueue) { [weak self] flag in
                guard let self else { return }
                guard let merged = state.notePlaying(flag, generation: generation) else { return }
                DispatchQueue.main.async {
                    self.consumeMediaRemote(info: merged.info, isPlaying: merged.playing, generation: generation)
                }
            }

            mediaQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                guard let merged = state.notePlayingTimeout(generation: generation) else { return }
                DispatchQueue.main.async {
                    self.consumeMediaRemote(info: merged.info, isPlaying: nil, generation: generation)
                }
            }
        }
    }

    private func consumeMediaRemote(info: NSDictionary?, isPlaying: Bool?, generation: UInt64) {
        guard generation == mediaFetchState.currentGeneration else { return }

        guard let info, info.count > 0 else {
            noteMediaRemoteMiss()
            return
        }

        let title = stringValue(info, [keyTitle, "kMRMediaRemoteNowPlayingInfoTitle", "title", "Title"])
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noteMediaRemoteMiss()
            return
        }

        mediaRemoteMisses = 0
        preferScriptFallback = false
        consecutiveEmptyFetches = 0

        let artist = stringValue(info, [keyArtist, "kMRMediaRemoteNowPlayingInfoArtist", "artist", "Artist"])
        let album = stringValue(info, [keyAlbum, "kMRMediaRemoteNowPlayingInfoAlbum", "album", "Album"])
        let duration = numberValue(info, [keyDuration, "kMRMediaRemoteNowPlayingInfoDuration", "duration", "Duration"]) ?? 0
        let elapsed = numberValue(info, [keyElapsed, "kMRMediaRemoteNowPlayingInfoElapsedTime", "elapsedTime", "ElapsedTime"]) ?? 0
        let rate = numberValue(info, [keyRate, "kMRMediaRemoteNowPlayingInfoPlaybackRate", "playbackRate", "PlaybackRate"]) ?? 1
        let artwork = dataValue(info, [keyArtwork, "kMRMediaRemoteNowPlayingInfoArtworkData", "artworkData"])

        let playing: Bool
        if let isPlaying {
            playing = isPlaying
        } else {
            playing = rate > 0.01
        }

        publish(
            title: title,
            artist: artist,
            album: album,
            isPlaying: playing,
            elapsed: elapsed,
            duration: duration,
            rate: rate,
            artwork: artwork,
            source: "MediaRemote"
        )
    }

    private func noteMediaRemoteMiss() {
        mediaRemoteMisses += 1
        if mediaRemoteMisses >= mediaRemoteMissThreshold {
            if !preferScriptFallback {
                preferScriptFallback = true
                print("[NowPlayingService] MediaRemote unavailable (misses=\(mediaRemoteMisses)) — switch to AppleScript fallback")
            }
            fetchViaAppleScript()
        } else {
            // 短暂空：不立刻清场，等脚本或下一次 MR
            consecutiveEmptyFetches += 1
            if consecutiveEmptyFetches >= emptyClearThreshold, !snapshot.hasMedia {
                apply(.empty)
            }
        }
    }

    // MARK: - AppleScript fallback (Music / Spotify)

    private func fetchViaAppleScript() {
        scriptQueue.async { [weak self] in
            let music = NowPlayingScriptBackend.readMusic()
            let spotify = music == nil ? NowPlayingScriptBackend.readSpotify() : nil
            let result = music ?? spotify
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.consecutiveEmptyFetches = 0
                    // 脚本源无封面；若已有同曲封面则保留
                    var art = result.artwork
                    if art == nil,
                       self.snapshot.title == result.title,
                       self.snapshot.artist == result.artist,
                       let existing = self.snapshot.artworkData {
                        art = existing
                    }
                    self.publish(
                        title: result.title,
                        artist: result.artist,
                        album: result.album,
                        isPlaying: result.isPlaying,
                        elapsed: result.elapsed,
                        duration: result.duration,
                        rate: result.isPlaying ? 1 : 0,
                        artwork: art,
                        source: result.source
                    )
                    // 若仍用脚本成功，保持 fallback，偶尔重试 MR
                    if self.mediaRemoteMisses > 0, self.mediaRemoteMisses % 15 == 0 {
                        self.preferScriptFallback = false
                    }
                } else if self.preferScriptFallback {
                    self.consecutiveEmptyFetches += 1
                    if self.consecutiveEmptyFetches >= self.emptyClearThreshold {
                        if self.snapshot.hasMedia {
                            print("[NowPlayingService] clear media (script empty ×\(self.consecutiveEmptyFetches))")
                        }
                        self.apply(.empty)
                    }
                }
            }
        }
    }

    // MARK: - Distributed notifications (Music)

    private func handleDistributedPlayerPayload(name: String, payload: DistributedPlayerPayload) {
        if payload.isEmpty {
            fetchViaAppleScript()
            return
        }
        let title = payload.title
        let state = payload.state.lowercased()
        var duration = payload.duration
        if duration > 10000 { duration /= 1000 } // Total Time 有时是毫秒
        let elapsed = payload.elapsed

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if state.contains("stop") {
                consecutiveEmptyFetches += 1
                if consecutiveEmptyFetches >= emptyClearThreshold {
                    apply(.empty)
                }
            }
            return
        }

        consecutiveEmptyFetches = 0
        let playing = state.contains("play") && !state.contains("pause")
        publish(
            title: title,
            artist: payload.artist,
            album: payload.album,
            isPlaying: playing || state.isEmpty,
            elapsed: elapsed,
            duration: duration,
            rate: playing ? 1 : 0,
            artwork: nil,
            source: "Distributed:\(name)"
        )
    }

    // MARK: - Publish / helpers

    private func publish(
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        elapsed: Double,
        duration: Double,
        rate: Double,
        artwork: Data?,
        source: String
    ) {
        let artHash = artwork.map { $0.hashValue } ?? 0
        let next = NowPlayingSnapshot(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            rate: rate > 0 ? rate : (isPlaying ? 1 : 0),
            artworkData: artwork,
            artworkHash: artHash
        )
        let wasEmpty = !snapshot.hasMedia
        apply(next)
        if wasEmpty {
            print("[NowPlayingService] media online source=\(source) title=\(title) artist=\(artist) playing=\(isPlaying)")
        }
    }

    private func apply(_ next: NowPlayingSnapshot) {
        let identity = "\(next.title)|\(next.artist)|\(next.album)|\(next.isPlaying)|\(next.artworkHash)|\(String(format: "%.1f", next.elapsed))|\(String(format: "%.1f", next.duration))"
        noteElapsed(from: next)
        if identity != lastInfoIdentity
            || snapshot.title != next.title
            || snapshot.artist != next.artist
            || snapshot.isPlaying != next.isPlaying
            || snapshot.artworkHash != next.artworkHash {
            lastInfoIdentity = identity
            snapshot = next
        } else if abs(snapshot.elapsed - next.elapsed) > 0.05 || abs(snapshot.duration - next.duration) > 0.05 {
            var copy = snapshot
            copy.elapsed = next.elapsed
            copy.duration = next.duration
            copy.rate = next.rate
            copy.isPlaying = next.isPlaying
            snapshot = copy
        }
    }

    private func noteElapsed(from track: NowPlayingSnapshot) {
        let base = max(0, track.elapsed)
        let rate = max(0, track.rate)
        let playing = track.isPlaying
        if abs(base - anchorBase) > 0.35 || playing != anchorPlaying || abs(rate - anchorRate) > 0.01 {
            anchorBase = base
            anchorAt = Date()
            anchorPlaying = playing
            anchorRate = rate > 0 ? rate : 1
        }
    }

    private func stringValue(_ info: NSDictionary, _ keys: [String]) -> String {
        for k in keys {
            if let s = info[k] as? String, !s.isEmpty { return s }
            if let s = info[k] as? NSString {
                let v = s as String
                if !v.isEmpty { return v }
            }
        }
        return ""
    }

    private func numberValue(_ info: NSDictionary, _ keys: [String]) -> Double? {
        for k in keys {
            if let n = info[k] as? NSNumber { return n.doubleValue }
            if let d = info[k] as? Double { return d }
            if let f = info[k] as? Float { return Double(f) }
        }
        return nil
    }

    private func dataValue(_ info: NSDictionary, _ keys: [String]) -> Data? {
        for k in keys {
            if let d = info[k] as? Data { return d }
            if let d = info[k] as? NSData { return d as Data }
        }
        return nil
    }

    private func numberFromAny(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Distributed player payload (Sendable)

private struct DistributedPlayerPayload: Sendable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var state: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var isEmpty: Bool { title.isEmpty && state.isEmpty && duration == 0 && elapsed == 0 }

    init(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return }
        func str(_ keys: [String]) -> String {
            for k in keys {
                if let s = userInfo[k] as? String { return s }
                if let s = userInfo[k] as? NSString { return s as String }
            }
            return ""
        }
        func num(_ keys: [String]) -> Double {
            for k in keys {
                if let n = userInfo[k] as? NSNumber { return n.doubleValue }
                if let d = userInfo[k] as? Double { return d }
                if let i = userInfo[k] as? Int { return Double(i) }
                if let s = userInfo[k] as? String, let d = Double(s) { return d }
            }
            return 0
        }
        title = str(["Name", "kMRMediaRemoteNowPlayingInfoTitle"])
        artist = str(["Artist"])
        album = str(["Album"])
        state = str(["Player State"])
        duration = num(["Total Time", "duration"])
        elapsed = num(["Playback Position", "Player Position"])
    }
}

// MARK: - MediaRemote fetch merge (thread-safe, nonisolated)

private final class MediaRemoteFetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingInfo: NSDictionary?
    private var pendingInfoReady = false
    private var pendingPlaying: Bool?
    private var pendingPlayingReady = false

    struct Merged {
        let info: NSDictionary?
        let playing: Bool?
    }

    var currentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func beginFetch() -> UInt64 {
        lock.lock()
        generation &+= 1
        let gen = generation
        pendingInfo = nil
        pendingInfoReady = false
        pendingPlaying = nil
        pendingPlayingReady = false
        lock.unlock()
        return gen
    }

    func noteInfo(_ info: NSDictionary?, generation gen: UInt64, playingOptional: Bool) -> Merged? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return nil }
        pendingInfo = info
        pendingInfoReady = true
        if pendingPlayingReady || playingOptional {
            return Merged(info: info, playing: playingOptional ? nil : pendingPlaying)
        }
        return nil
    }

    func notePlaying(_ flag: Bool, generation gen: UInt64) -> Merged? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return nil }
        pendingPlaying = flag
        pendingPlayingReady = true
        guard pendingInfoReady else { return nil }
        return Merged(info: pendingInfo, playing: flag)
    }

    func notePlayingTimeout(generation gen: UInt64) -> Merged? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return nil }
        guard pendingInfoReady, !pendingPlayingReady else { return nil }
        pendingPlayingReady = true
        return Merged(info: pendingInfo, playing: nil)
    }
}

// MARK: - AppleScript backend (nonisolated)

private enum NowPlayingScriptBackend {
    struct ScriptTrack: Sendable {
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var artwork: Data?
        var source: String
    }

    /// 按 title|artist 缓存封面，避免每秒 poll 都写盘
    private static let artworkCache = ArtworkCache()

    private final class ArtworkCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String = ""
        private var data: Data?

        func data(for key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return self.key == key ? data : nil
        }

        func store(_ data: Data?, for key: String) {
            lock.lock()
            self.key = key
            self.data = data
            lock.unlock()
        }
    }

    static func readMusic() -> ScriptTrack? {
        // 注意：勿用 `player state as string` / 短变量名 `st`——在部分系统/本地化下会语法失败 (-2741)。
        // 用 boolean 判断 playing，字段用 || 分隔（歌名极少含双竖线）。
        let script = """
        tell application "System Events"
          if not (exists process "Music") then return ""
        end tell
        tell application "Music"
          if player state is stopped then return ""
          set isPlay to (player state is playing)
          set trackName to name of current track
          set trackArtist to artist of current track
          set trackAlbum to album of current track
          set pos to player position
          set dur to duration of current track
          set flag to "paused"
          if isPlay then set flag to "playing"
          return trackName & "||" & trackArtist & "||" & trackAlbum & "||" & flag & "||" & (pos as string) & "||" & (dur as string)
        end tell
        """
        guard var track = parse(runOsascript(script), source: "Music.applescript", sep: "||", durationIsMillis: false) else {
            return nil
        }
        let key = "\(track.title)|\(track.artist)"
        if let cached = artworkCache.data(for: key) {
            track.artwork = cached
        } else if let art = readMusicArtwork() {
            artworkCache.store(art, for: key)
            track.artwork = art
        } else {
            // 换歌但无封面：清缓存，避免沿用上一首
            artworkCache.store(nil, for: key)
        }
        return track
    }

    /// 把当前曲封面写到临时文件再读回（Music 的 artwork data 是 raw PNG/JPEG）
    private static func readMusicArtwork() -> Data? {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("waifux-nowplaying-art-\(ProcessInfo.processInfo.processIdentifier).bin")
        let path = outURL.path
        // 用 quoted form of POSIX path，避免路径里空格/中文
        let script = """
        set outPath to POSIX file "\(path)"
        tell application "Music"
          try
            if (count of artworks of current track) is 0 then return "NO_ART"
            set raw to data of artwork 1 of current track
          on error
            return "NO_ART"
          end try
        end tell
        try
          set f to open for access outPath with write permission
          set eof f to 0
          write raw to f
          close access f
          return "OK"
        on error
          try
            close access outPath
          end try
          return "WRITE_ERR"
        end try
        """
        guard runOsascript(script) == "OK" else { return nil }
        defer { try? FileManager.default.removeItem(at: outURL) }
        guard let data = try? Data(contentsOf: outURL), !data.isEmpty else { return nil }
        // 只接受常见图片头，避免写进脏数据
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data } // PNG
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return data } // JPEG
        if data.count > 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 { return data } // RIFF/WebP
        return data // 仍返回，让 NSImage 尝试
    }

    static func readSpotify() -> ScriptTrack? {
        let script = """
        tell application "System Events"
          if not (exists process "Spotify") then return ""
        end tell
        tell application "Spotify"
          if player state is stopped then return ""
          set isPlay to (player state is playing)
          set trackName to name of current track
          set trackArtist to artist of current track
          set trackAlbum to album of current track
          set pos to player position
          set dur to (duration of current track) / 1000
          set flag to "paused"
          if isPlay then set flag to "playing"
          return trackName & "||" & trackArtist & "||" & trackAlbum & "||" & flag & "||" & (pos as string) & "||" & (dur as string)
        end tell
        """
        return parse(runOsascript(script), source: "Spotify.applescript", sep: "||", durationIsMillis: false)
    }

    private static func runOsascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func parse(_ raw: String?, source: String, sep: String, durationIsMillis: Bool) -> ScriptTrack? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: sep)
        guard parts.count >= 6 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let state = parts[3].lowercased()
        let playing = state.contains("play") // playing
        var duration = Double(parts[5]) ?? 0
        if durationIsMillis { duration /= 1000 }
        return ScriptTrack(
            title: title,
            artist: parts[1],
            album: parts[2],
            isPlaying: playing,
            elapsed: Double(parts[4]) ?? 0,
            duration: duration,
            artwork: nil,
            source: source
        )
    }
}

// MARK: - Thumbnail helpers

public enum NowPlayingThumbnail {
    public static func jpegDataURL(from data: Data, maxEdge: CGFloat = 320, quality: CGFloat = 0.72) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
