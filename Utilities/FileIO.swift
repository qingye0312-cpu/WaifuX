import Foundation

// MARK: - 后台文件 I/O 工具

/// 在全局后台队列上执行同步文件写入，避免阻塞 MainActor。
/// Data.write(to:options:) 同步写入大文件（MB 级图片/视频）时，
/// 若在 @MainActor 上下文中调用会导致主线程卡死。
extension Data {
    /// 在全局后台队列执行文件写入，返回后调用者仍在原 Actor 上。
    func writeAsync(to url: URL, options: Data.WritingOptions = []) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.write(to: url, options: options)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// 在全局后台队列上读取文件内容，避免阻塞 MainActor。
extension URL {
    /// 在后台队列同步读取文件内容，返回后调用者仍在原 Actor 上。
    func readDataAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Data(contentsOf: self)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 在后台队列检查文件是否存在，避免阻塞 MainActor。
    /// 适合已知可能存在的文件路径检查；高频场景应使用 FileExistenceCache。
    func fileExistsAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let exists = FileManager.default.fileExists(atPath: self.path)
                continuation.resume(returning: exists)
            }
        }
    }
}

// MARK: - 文件存在性内存缓存

/// 轻量级的文件存在性内存缓存，避免在主线程反复调用 FileManager.fileExists(atPath:)。
/// 适用于「我的库」等有上千条下载记录的场景。
///
/// 外置卡/U 盘上 `fileExists` 本身可能要几十～几百毫秒；命中负缓存与正缓存同样重要。
/// 「乐观存在」：下载记录写入后 markExisting，列表滚动不再打慢卷。
final class FileExistenceCache: @unchecked Sendable {
    static let shared = FileExistenceCache()

    private let cache = NSCache<NSString, NSNumber>()
    /// 路径 → 是否目录（workshop 根等）；与 fileExists 共用成本限额
    private let directoryCache = NSCache<NSString, NSNumber>()

    private init() {
        cache.countLimit = 8000
        cache.totalCostLimit = 4 * 1024 * 1024
        directoryCache.countLimit = 2000
    }

    /// 检查文件是否存在（优先缓存，未命中时调用 FileManager）
    func fileExists(atPath path: String) -> Bool {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached.boolValue
        }
        let exists = FileManager.default.fileExists(atPath: path)
        cache.setObject(NSNumber(value: exists), forKey: key, cost: path.utf8.count)
        return exists
    }

    /// 检查路径是否为目录（缓存结果，避免列表/卡片反复 stat 外置卷）
    func isDirectory(atPath path: String) -> Bool {
        let key = path as NSString
        if let cached = directoryCache.object(forKey: key) {
            return cached.boolValue
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let result = exists && isDir.boolValue
        directoryCache.setObject(NSNumber(value: result), forKey: key, cost: path.utf8.count)
        if exists {
            cache.setObject(NSNumber(value: true), forKey: key, cost: path.utf8.count)
        }
        return result
    }

    /// 标记文件为「存在」（下载完成后调用，避免后续检查再走 FileManager）
    func markExisting(atPath path: String) {
        cache.setObject(NSNumber(value: true), forKey: path as NSString, cost: path.utf8.count)
    }

    /// 标记路径为目录（导入 Workshop 项目后调用）
    func markDirectory(atPath path: String) {
        let key = path as NSString
        cache.setObject(NSNumber(value: true), forKey: key, cost: path.utf8.count)
        directoryCache.setObject(NSNumber(value: true), forKey: key, cost: path.utf8.count)
    }

    /// 失效指定路径的缓存
    func invalidate(atPath path: String) {
        let key = path as NSString
        cache.removeObject(forKey: key)
        directoryCache.removeObject(forKey: key)
    }

    /// 失效指定目录下的所有缓存（通过路径前缀匹配）
    func invalidateDirectory(_ dirPath: String) {
        // NSCache 不支持遍历，所以只清所有
        clearAll()
    }

    /// 清空所有缓存（内存压力时调用）
    func clearAll() {
        cache.removeAllObjects()
        directoryCache.removeAllObjects()
    }
}
