import Foundation

/// 本地壁纸扫描服务
/// 自动检测用户复制到下载目录的壁纸和媒体文件，生成基本元数据
@MainActor
final class LocalWallpaperScanner {
    static let shared = LocalWallpaperScanner()
    
    private let downloadPathManager = DownloadPathManager.shared
    private let fileManager = FileManager.default
    
    // 缓存扫描结果
    private var scannedWallpapers: [LocalWallpaperItem] = []
    private var scannedMediaItems: [LocalMediaItem] = []
    private var lastScanTime: Date?
    private var scanTask: Task<Void, Never>?
    
    /// 扫描版本号，扫描完成后递增，供 ViewModel 监听以重建缓存
    @Published private(set) var scanRevision: UInt = 0
    
    // 扫描间隔（秒）- 增加到 30 秒避免频繁扫描
    private let scanInterval: TimeInterval = 30
    
    private init() {}
    
    // MARK: - 公共方法
    
    /// 获取所有本地壁纸（包括扫描到的文件）
    /// - Returns: 本地壁纸项目数组
    func getLocalWallpapers() -> [LocalWallpaperItem] {
        scheduleScanIfNeeded()
        return scannedWallpapers
    }
    
    /// 获取所有本地媒体（包括扫描到的文件）
    /// - Returns: 本地媒体项目数组
    func getLocalMedia() -> [LocalMediaItem] {
        scheduleScanIfNeeded()
        return scannedMediaItems
    }
    
    /// 强制重新扫描本地文件
    func forceRescan() async {
        await scanLocalFiles(force: true)
    }

    /// 主窗口长期隐藏后释放前台库列表缓存；下次打开时按需重新扫描。
    func clearInMemoryCache() {
        scannedWallpapers.removeAll()
        scannedMediaItems.removeAll()
        lastScanTime = nil
        scanRevision &+= 1
    }
    
    /// 根据文件路径查找或创建壁纸对象
    /// - Parameter fileURL: 文件 URL
    /// - Returns: 本地壁纸项目
    func wallpaperForFile(_ fileURL: URL) -> LocalWallpaperItem? {
        // 先检查缓存
        if let cached = scannedWallpapers.first(where: { $0.fileURL.path == fileURL.path }) {
            return cached
        }
        
        // 实时创建
        return createWallpaperItem(from: fileURL)
    }
    
    /// 根据文件路径查找或创建媒体对象
    /// - Parameter fileURL: 文件 URL
    /// - Returns: 本地媒体项目
    func mediaForFile(_ fileURL: URL) async -> LocalMediaItem? {
        if let cached = scannedMediaItems.first(where: { $0.fileURL.path == fileURL.path }) {
            return cached
        }
        return await createMediaItem(from: fileURL)
    }
    
    // MARK: - 扫描逻辑
    
    private func shouldRescan() -> Bool {
        guard let lastScan = lastScanTime else { return true }
        return Date().timeIntervalSince(lastScan) > scanInterval
    }

    private func scheduleScanIfNeeded() {
        guard shouldRescan() else { return }
        guard scanTask == nil else { return }

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
        }
    }

    private func scanLocalFiles(force: Bool = false) async {
        if !force && !shouldRescan() {
            return
        }

        if let scanTask {
            await scanTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
        }
        scanTask = task
        await task.value
    }

    private func runScan() async {
        defer { scanTask = nil }

        let startTime = Date()
        print("[LocalWallpaperScanner] Starting local file scan...")

        // 路径在 MainActor 解析（security-scoped）；目录枚举/轻量元数据放到后台，避免卡 UI。
        let wallpapersFolder = downloadPathManager.wallpapersFolderURL
        let mediaFolder = downloadPathManager.mediaFolderURL

        let (wallpapers, mediaItems) = await Task.detached(priority: .utility) {
            var wallpapers: [LocalWallpaperItem] = []
            var mediaItems: [LocalMediaItem] = []
            let fm = FileManager.default

            if fm.fileExists(atPath: wallpapersFolder.path) {
                do {
                    let contents = try fm.contentsOfDirectory(
                        at: wallpapersFolder,
                        includingPropertiesForKeys: [
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey
                        ],
                        options: .skipsHiddenFiles
                    )
                    for fileURL in contents where Self.isImageFileStatic(fileURL) {
                        if let item = Self.createWallpaperItemLightweight(from: fileURL) {
                            wallpapers.append(item)
                        }
                    }
                } catch {
                    print("[LocalWallpaperScanner] Failed to scan wallpapers folder: \(error)")
                }
            }

            if fm.fileExists(atPath: mediaFolder.path) {
                do {
                    let contents = try fm.contentsOfDirectory(
                        at: mediaFolder,
                        includingPropertiesForKeys: [
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey
                        ],
                        options: .skipsHiddenFiles
                    )
                    for fileURL in contents where Self.isVideoFileStatic(fileURL) {
                        if let item = Self.createMediaItemLightweight(from: fileURL) {
                            mediaItems.append(item)
                        }
                    }
                } catch {
                    print("[LocalWallpaperScanner] Failed to scan media folder: \(error)")
                }
            }

            return (wallpapers, mediaItems)
        }.value

        // 预热存在性缓存，列表 isDownloaded / localFileURL 不再 stat 外置卷
        for item in wallpapers {
            FileExistenceCache.shared.markExisting(atPath: item.fileURL.path)
        }
        for item in mediaItems {
            FileExistenceCache.shared.markExisting(atPath: item.fileURL.path)
        }

        scannedWallpapers = wallpapers
        scannedMediaItems = mediaItems
        lastScanTime = Date()
        scanRevision &+= 1

        print("[LocalWallpaperScanner] Scan completed in \(Date().timeIntervalSince(startTime))s, found \(wallpapers.count) wallpapers, \(mediaItems.count) media files")

        // 列表缩略图在可见卡片 onAppear 时按需生成；扫描阶段不读全图、不抽视频帧
    }

    // MARK: - 创建元数据

    /// 列表扫描用：只读目录项 resourceValues，不打开 ImageIO/AVAsset（外置卡上极慢）。
    nonisolated private static func createWallpaperItemLightweight(from fileURL: URL) -> LocalWallpaperItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let id = "local_\(fileName)_\(fileExtension)"
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate ?? values?.contentModificationDate
        let createdAt = created.map { ISO8601DateFormatter().string(from: $0) }

        return LocalWallpaperItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: fileName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "),
            // 分辨率延后到详情/需要筛选时再读；列表滚动不依赖精确像素
            resolution: "Unknown",
            dimensionX: 1920,
            dimensionY: 1080,
            ratio: "1.78",
            fileSize: values?.fileSize,
            fileType: mimeTypeStatic(fileExtension),
            createdAt: createdAt
        )
    }

    nonisolated private static func createMediaItemLightweight(from fileURL: URL) -> LocalMediaItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let (parsedTitle, parsedResolution) = parseMediaFileNameStatic(fileName)
        let id = "local_\(fileName)_\(fileExtension)"
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate ?? values?.contentModificationDate
        let createdAt = created.map { ISO8601DateFormatter().string(from: $0) }

        return LocalMediaItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: parsedTitle,
            resolution: parsedResolution,
            duration: nil,
            fileSize: values?.fileSize,
            fileType: mimeTypeStatic(fileExtension),
            createdAt: createdAt
        )
    }

    private func createWallpaperItem(from fileURL: URL) -> LocalWallpaperItem? {
        Self.createWallpaperItemLightweight(from: fileURL)
    }

    private func createMediaItem(from fileURL: URL) async -> LocalMediaItem? {
        Self.createMediaItemLightweight(from: fileURL)
    }

    nonisolated private static func isImageFileStatic(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"].contains(ext)
    }

    nonisolated private static func isVideoFileStatic(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv"].contains(ext)
    }

    nonisolated private static func mimeTypeStatic(_ ext: String) -> String? {
        let typeMap: [String: String] = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "webp": "image/webp", "gif": "image/gif", "bmp": "image/bmp",
            "tiff": "image/tiff", "heic": "image/heic",
            "mp4": "video/mp4", "mov": "video/quicktime", "avi": "video/x-msvideo",
            "mkv": "video/x-matroska", "webm": "video/webm", "m4v": "video/x-m4v",
            "flv": "video/x-flv"
        ]
        return typeMap[ext]
    }

    nonisolated private static func parseMediaFileNameStatic(_ fileName: String) -> (title: String, resolution: String?) {
        let patterns = [
            ("(\\d{3,4})p", 1),
            ("(\\d{4})x(\\d{3,4})", 0),
            ("(4k|8k|2k)", 1),
            ("(hd|fullhd|fhd)", 1),
        ]
        var foundResolution: String?
        var modifiedName = fileName
        for (pattern, group) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(modifiedName.startIndex..., in: modifiedName)
                if let match = regex.firstMatch(in: modifiedName, options: [], range: range) {
                    if let resolutionRange = Range(match.range(at: group), in: modifiedName) {
                        foundResolution = String(modifiedName[resolutionRange]).uppercased()
                    }
                    modifiedName = regex.stringByReplacingMatches(
                        in: modifiedName,
                        options: [],
                        range: range,
                        withTemplate: ""
                    )
                }
            }
        }
        let cleanTitle = modifiedName
            .replacingOccurrences(of: "motionbgs-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "wallhaven-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleanTitle.isEmpty ? fileName : cleanTitle, foundResolution)
    }
    
    // 图片/视频像素与时长改由详情页/设壁纸路径按需读取；
    // 列表扫描只保留目录项 resourceValues，避免外置卡上 ImageIO/AVAsset 全量 I/O。
}

// MARK: - 本地壁纸项目

struct LocalWallpaperItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let fileName: String
    let title: String
    let resolution: String
    let dimensionX: Int
    let dimensionY: Int
    let ratio: String
    let fileSize: Int?
    let fileType: String?
    let createdAt: String?
    
    /// 转换为 Wallpaper 对象（用于详情页）
    func toWallpaper() -> Wallpaper {
        Wallpaper(
            id: id,
            title: nil,
            url: fileURL.absoluteString,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: "local",
            purity: "sfw",
            category: "general",
            dimensionX: dimensionX,
            dimensionY: dimensionY,
            resolution: resolution,
            ratio: ratio,
            fileSize: fileSize,
            fileType: fileType,
            createdAt: createdAt,
            colors: [],
            path: fileURL.absoluteString,
            thumbs: Wallpaper.Thumbs(
                large: fileURL.absoluteString,
                original: fileURL.absoluteString,
                small: fileURL.absoluteString
            ),
            tags: nil,
            uploader: nil
        )
    }
}

// MARK: - 本地媒体项目

struct LocalMediaItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let fileName: String
    let title: String
    let resolution: String?
    let duration: Double?
    let fileSize: Int?
    let fileType: String?
    let createdAt: String?
    
    /// 转换为 MediaItem 对象（用于详情页）
    @MainActor
    func toMediaItem() -> MediaItem {
        let resolutionLabel = resolution ?? "HD"
        
        // 列表缩略图（800×600）；锁屏/桌面请用 posterJPEG / existingWallpaperPoster，不得复用列表小图
        let listThumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)
        let hdPosterURL = VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: fileURL)
        
        return MediaItem(
            slug: id,
            title: title,
            pageURL: fileURL,
            thumbnailURL: listThumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("local.files"),
            summary: t("local.imported.video"),
            previewVideoURL: fileURL,
            posterURL: hdPosterURL,
            tags: ["local", fileURL.pathExtension.lowercased()],
            exactResolution: resolution,
            durationSeconds: duration,
            downloadOptions: [], // 本地文件没有下载选项
            sourceName: t("local")
        )
    }
    
    /// 时长格式化
    var durationLabel: String? {
        guard let duration = duration else { return nil }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// 文件大小格式化
    var fileSizeLabel: String? {
        guard let size = fileSize else { return nil }
        let mb = Double(size) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
