import Foundation
import AppKit
import AVFoundation

// MARK: - 导入进度

struct ImportProgress: Equatable {
    /// 当前正在处理的文件名
    var currentFileName = ""
    /// 本次导入的文件总数（展开目录后）
    var totalFiles = 0
    /// 已处理的文件数
    var completedFiles = 0
    /// 成功导入数
    var successfulImports = 0
    /// 失败数
    var failedImports = 0
    /// 用户选择跳过的同名冲突数
    var skippedImports = 0
    /// 是否已被取消
    var isCancelled = false

    var isFinished: Bool {
        completedFiles >= totalFiles && totalFiles > 0
    }

    var fractionCompleted: Double {
        guard totalFiles > 0 else { return 0 }
        return min(Double(completedFiles) / Double(totalFiles), 1.0)
    }

    /// 合并另一个进度（用于 TaskGroup 累加）
    static func + (lhs: ImportProgress, rhs: ImportProgress) -> ImportProgress {
        ImportProgress(
            currentFileName: rhs.currentFileName.isEmpty ? lhs.currentFileName : rhs.currentFileName,
            totalFiles: lhs.totalFiles + rhs.totalFiles,
            completedFiles: lhs.completedFiles + rhs.completedFiles,
            successfulImports: lhs.successfulImports + rhs.successfulImports,
            failedImports: lhs.failedImports + rhs.failedImports,
            skippedImports: lhs.skippedImports + rhs.skippedImports,
            isCancelled: lhs.isCancelled || rhs.isCancelled
        )
    }
}

// MARK: - 导入结果

struct ImportResult {
    let totalFiles: Int
    let successfulImports: Int
    let failedImports: Int
    let skippedImports: Int

    var hasFailures: Bool { failedImports > 0 }
    var allSucceeded: Bool { failedImports == 0 && skippedImports == 0 && successfulImports > 0 }
    var message: String {
        if allSucceeded {
            return String(format: t("import.result.success"), successfulImports)
        } else if hasFailures || skippedImports > 0 {
            if skippedImports > 0 && failedImports == 0 {
                return String(format: t("import.result.partial.skipped"), successfulImports, skippedImports)
            }
            return String(format: t("import.result.partial"), successfulImports, failedImports)
        } else {
            return t("import.result.none")
        }
    }
}

/// 导入同名冲突时的处理策略
enum ImportConflictAction: Equatable {
    /// 覆盖库中已有文件/目录
    case replace
    /// 自动重命名后保留双方（如 `pic0 2.png`）
    case keepRenamed
    /// 跳过当前项
    case skip
}

// MARK: - 统一导入服务

/// 统一导入服务：自动识别文件类型并路由到正确的库。
///
/// 支持的输入：
/// - 图片文件 → 壁纸库（`Wallpapers/`）
/// - 视频文件 → 媒体库（`Media/`）
/// - 目录（含 project.json）→ Workshop 导入（`Media/workshop_{id}/`）
/// - `.pkg` 文件 → 取其父目录作为 Workshop 源
@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

    @Published var isImporting = false
    @Published var progress = ImportProgress()

    private let wallpaperLibrary = WallpaperLibraryService.shared
    private let mediaLibrary = MediaLibraryService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private let fileManager = FileManager.default
    private var currentTask: Task<Void, Never>?
    /// 批量导入时「应用到全部」记住的冲突策略
    private var rememberedConflictAction: ImportConflictAction?

    private init() {}

    // MARK: - 公开方法

    /// 取消当前正在进行的导入
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        progress.isCancelled = true
        isImporting = false
        rememberedConflictAction = nil
    }

    /// 导入指定的 URL 列表（文件/目录混合）
    /// - Parameters:
    ///   - urls: 用户选择的文件或目录 URL
    ///   - folderID: 可选，导入后自动归入的文件夹 ID
    func importURLs(_ urls: [URL], folderID: String? = nil) async {
        // 防止重复调用
        guard !isImporting else { return }
        isImporting = true
        progress = ImportProgress()
        rememberedConflictAction = nil

        currentTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isImporting = false
                self.currentTask = nil
                self.rememberedConflictAction = nil
            }

            // 第一步：展开所有 URL，收集待处理的导入项
            let items = await self.collectImportItems(from: urls)
            guard !items.isEmpty, !Task.isCancelled else {
                self.progress.totalFiles = 0
                self.progress.completedFiles = 0
                return
            }

            self.progress.totalFiles = items.count

            // 第二步：逐项处理（文件 I/O 为主，顺序执行避免并发竞争）
            var totalSuccess = 0
            var totalFailed = 0
            var totalSkipped = 0

            for item in items {
                guard !Task.isCancelled else { break }

                self.progress.currentFileName = item.displayName

                let outcome = await self.processImportItem(item, folderID: folderID)

                self.progress.completedFiles += 1
                switch outcome {
                case .success:
                    self.progress.successfulImports += 1
                    totalSuccess += 1
                case .skipped:
                    self.progress.skippedImports += 1
                    totalSkipped += 1
                case .failed:
                    self.progress.failedImports += 1
                    totalFailed += 1
                }
            }

            let result = ImportResult(
                totalFiles: items.count,
                successfulImports: totalSuccess,
                failedImports: totalFailed,
                skippedImports: totalSkipped
            )

            // 第三步：完成后触发扫描刷新
            if result.allSucceeded || result.hasFailures || totalSkipped > 0 {
                await LocalWallpaperScanner.shared.forceRescan()
                // 发送变更通知，让 ViewModel 知道内容变了
                NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)
                print("[ImportService] Import completed: \(result.message)")
            }
        }

        await currentTask?.value
    }

    // MARK: - 导入项分类

    private enum ImportItemType {
        case wallpaper(sourceURL: URL)
        case media(sourceURL: URL)
        case workshop(directoryURL: URL, projectJSONURL: URL, json: [String: Any])
    }

    private struct ImportItem {
        let type: ImportItemType
        var displayName: String {
            switch type {
            case .wallpaper(let url), .media(let url):
                return url.lastPathComponent
            case .workshop(let dirURL, _, _):
                return dirURL.lastPathComponent
            }
        }
    }

    /// 展开用户选择的 URL，收集所有待导入项
    private func collectImportItems(from urls: [URL]) async -> [ImportItem] {
        var items: [ImportItem] = []

        for url in urls {
            guard !Task.isCancelled else { break }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // 目录：先收集 Workshop 项目（含 project.json），支持父目录批量导入
                let workshopItems = findWorkshopItems(in: url)
                if !workshopItems.isEmpty {
                    items.append(contentsOf: workshopItems)
                    // 同级/树内的松散图片/视频仍可导入，但会跳过 workshop 工程树与 preview.*
                    let looseItems = await scanDirectory(url)
                    items.append(contentsOf: looseItems)
                } else {
                    // 普通目录：递归扫描子文件（跳过 WE preview 与 workshop 工程树内文件）
                    let subItems = await scanDirectory(url)
                    items.append(contentsOf: subItems)
                }
            } else {
                // 文件
                let ext = url.pathExtension.lowercased()
                if ext == "pkg" {
                    // .pkg 文件：取上级目录作为 Workshop 源
                    let parentDir = url.deletingLastPathComponent()
                    let workshopItems = findWorkshopItems(in: parentDir)
                    if let workshopItem = workshopItems.first {
                        items.append(workshopItem)
                    } else {
                        print("[ImportService] .pkg file found but no project.json in parent dir: \(parentDir.path)")
                    }
                } else if isImageFile(url) {
                    // 用户显式选中 preview.* 时仍导入；目录扫描路径会过滤
                    items.append(ImportItem(type: .wallpaper(sourceURL: url)))
                } else if isVideoFile(url) {
                    items.append(ImportItem(type: .media(sourceURL: url)))
                } else {
                    print("[ImportService] Skipping unsupported file: \(url.lastPathComponent)")
                }
            }
        }

        return items
    }

    /// 递归扫描目录中的所有支持文件
    private func scanDirectory(_ dir: URL) async -> [ImportItem] {
        var items: [ImportItem] = []

        // 在同步上下文中收集文件，避免 FileManager.Enumerator 的 Sequence 冲突
        let collectedURLs: [URL] = {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var urls: [URL] = []
            for case let fileURL as URL in enumerator {
                var isDir: AnyObject?
                try? (fileURL as NSURL).getResourceValue(&isDir, forKey: URLResourceKey.isDirectoryKey)
                let isDirectory = isDir as? Bool ?? false

                // 跳过 Workshop 工程目录树：整体由 workshop 导入路径处理，
                // 避免把 project 内的 preview.jpg / scene 贴图等当成独立壁纸。
                if isDirectory,
                   fileManager.fileExists(atPath: fileURL.appendingPathComponent("project.json").path) {
                    enumerator.skipDescendants()
                    continue
                }
                if isInsideWorkshopProject(fileURL, under: dir) {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                if isDirectory { continue }
                urls.append(fileURL)
            }
            return urls
        }()

        for fileURL in collectedURLs {
            guard !Task.isCancelled else { break }

            // WE 工程预览图命名固定为 preview.*，目录扫描时不得单独入库
            if isWorkshopPreviewImage(fileURL) {
                print("[ImportService] Skipping workshop preview image: \(fileURL.lastPathComponent)")
                continue
            }

            if isImageFile(fileURL) {
                items.append(ImportItem(type: .wallpaper(sourceURL: fileURL)))
            } else if isVideoFile(fileURL) {
                items.append(ImportItem(type: .media(sourceURL: fileURL)))
            }
        }
        return items
    }

    /// 在指定目录中收集所有 Workshop 项目（每个 project.json 一项）
    /// - 单工程目录：返回该项
    /// - 父目录下挂多个 workshop 子目录：全部返回，避免只导第一个
    private func findWorkshopItems(in dir: URL) -> [ImportItem] {
        // 当前目录本身就是工程根
        let rootProject = dir.appendingPathComponent("project.json")
        if fileManager.fileExists(atPath: rootProject.path),
           let item = makeWorkshopImportItem(projectRoot: dir, projectJSONURL: rootProject) {
            return [item]
        }

        // 批量优先：直接子目录各自是 workshop 工程
        // （必须先于 resolve，否则父目录会被 resolve 到「第一个」子工程而漏导）
        guard let children = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [ImportItem] = []
        var seenRoots = Set<String>()
        for child in children {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: child)
            let projectURL = projectRoot.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: projectURL.path) else { continue }
            let key = projectRoot.standardizedFileURL.path
            guard seenRoots.insert(key).inserted else { continue }
            if let item = makeWorkshopImportItem(projectRoot: projectRoot, projectJSONURL: projectURL) {
                items.append(item)
            }
        }
        if !items.isEmpty {
            return items
        }

        // 单工程壳目录（如 content/<id> 再往下一层才有 project.json）
        let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: dir)
        if resolved.standardizedFileURL != dir.standardizedFileURL {
            let resolvedProject = resolved.appendingPathComponent("project.json")
            if fileManager.fileExists(atPath: resolvedProject.path),
               let item = makeWorkshopImportItem(projectRoot: resolved, projectJSONURL: resolvedProject) {
                return [item]
            }
        }
        return []
    }

    private func makeWorkshopImportItem(projectRoot: URL, projectJSONURL: URL) -> ImportItem? {
        guard let data = try? Data(contentsOf: projectJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ImportItem(
            type: .workshop(
                directoryURL: projectRoot,
                projectJSONURL: projectJSONURL,
                json: json
            )
        )
    }

    /// 文件是否位于某个含 project.json 的 Workshop 工程目录下（含扫描根自身）
    private func isInsideWorkshopProject(_ fileURL: URL, under scanRoot: URL) -> Bool {
        let rootPath = scanRoot.standardizedFileURL.path
        var current = fileURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let currentPath = current.path
            // 仅检查扫描根及其子路径
            guard currentPath == rootPath || currentPath.hasPrefix(rootPath + "/") else {
                return false
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent("project.json").path) {
                return true
            }
            if currentPath == rootPath { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == currentPath { return false }
            current = parent
        }
    }

    /// Wallpaper Engine 工程固定预览图名（大小写不敏感）
    private func isWorkshopPreviewImage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "preview.jpg"
            || name == "preview.jpeg"
            || name == "preview.png"
            || name == "preview.webp"
            || name == "preview.gif"
    }

    // MARK: - 处理单个导入项

    private enum ImportOutcome {
        case success
        case skipped
        case failed
    }

    private func processImportItem(_ item: ImportItem, folderID: String?) async -> ImportOutcome {
        switch item.type {
        case .wallpaper(let sourceURL):
            return await importWallpaper(from: sourceURL, folderID: folderID)
        case .media(let sourceURL):
            return await importMedia(from: sourceURL, folderID: folderID)
        case .workshop(let dirURL, let projectJSONURL, let json):
            return await importWorkshop(
                sourceDir: dirURL,
                projectJSONURL: projectJSONURL,
                json: json,
                folderID: folderID
            )
        }
    }

    // MARK: - 同名冲突处理

    /// 解析目标路径冲突：不存在则直接可用；内容相同则跳过；否则询问替换 / 自动重命名 / 跳过。
    private func resolveDestinationURL(
        preferred: URL,
        sourceURL: URL
    ) async -> (url: URL, shouldReplace: Bool)? {
        let src = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let preferredStd = preferred.resolvingSymlinksInPath().standardizedFileURL

        // 源与目标为同一路径（从库目录自身导入）→ 已在库中，跳过
        if src == preferredStd {
            return nil
        }

        guard fileManager.fileExists(atPath: preferredStd.path) else {
            return (preferred, false)
        }

        // 同名且内容相同（文件字节一致 / Workshop 目录结构与体积一致）→ 自动跳过，不打扰用户
        if itemsAppearIdentical(source: src, existing: preferredStd) {
            print("[ImportService] Skip identical item: \(preferredStd.lastPathComponent)")
            return nil
        }

        let action: ImportConflictAction
        if let remembered = rememberedConflictAction {
            action = remembered
        } else {
            let remaining = max(progress.totalFiles - progress.completedFiles, 1)
            let decision = askConflictDecision(
                existingName: preferred.lastPathComponent,
                remainingCount: remaining
            )
            if decision.applyToAll {
                rememberedConflictAction = decision.action
            }
            action = decision.action
        }

        switch action {
        case .replace:
            return (preferred, true)
        case .keepRenamed:
            let unique = makeUniqueSiblingURL(for: preferred)
            return (unique, false)
        case .skip:
            return nil
        }
    }

    /// 判断源与库中已有项是否实质相同。
    /// - 普通文件：`contentsEqual`
    /// - 目录（Workshop）：递归比较相对路径集合 + 各文件大小（不逐字节扫大包，兼顾准确与性能）
    private func itemsAppearIdentical(source: URL, existing: URL) -> Bool {
        var srcIsDir: ObjCBool = false
        var dstIsDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &srcIsDir),
              fileManager.fileExists(atPath: existing.path, isDirectory: &dstIsDir) else {
            return false
        }
        if srcIsDir.boolValue != dstIsDir.boolValue {
            return false
        }
        if !srcIsDir.boolValue {
            return fileManager.contentsEqual(atPath: source.path, andPath: existing.path)
        }
        return directoriesAppearIdentical(source: source, existing: existing)
    }

    private func directoriesAppearIdentical(source: URL, existing: URL) -> Bool {
        guard let srcMap = directoryFileFingerprint(at: source),
              let dstMap = directoryFileFingerprint(at: existing) else {
            return false
        }
        return srcMap == dstMap
    }

    /// 目录指纹：相对路径 → 文件大小。隐藏文件 / 临时文件跳过。
    private func directoryFileFingerprint(at root: URL) -> [String: Int64]? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var map: [String: Int64] = [:]
        let rootPath = root.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isDirectory == true { continue }
            // 符号链接按目标是否存在计入路径，大小记 -1，避免把外链当普通文件误判相同
            if values?.isSymbolicLink == true {
                let rel = relativePath(of: fileURL, under: rootPath)
                map[rel] = -1
                continue
            }
            let size = Int64(values?.fileSize ?? 0)
            let rel = relativePath(of: fileURL, under: rootPath)
            map[rel] = size
        }
        return map
    }

    private func relativePath(of fileURL: URL, under rootPath: String) -> String {
        let path = fileURL.standardizedFileURL.path
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    /// 弹出原生 NSAlert：替换 / 保留（自动重命名）/ 跳过；多项时可勾选「应用到全部」。
    private func askConflictDecision(
        existingName: String,
        remainingCount: Int
    ) -> (action: ImportConflictAction, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = t("import.conflict.title")
        alert.informativeText = String(
            format: t("import.conflict.message"),
            existingName
        )
        alert.alertStyle = .warning
        // 按钮顺序：默认「保留」更安全；替换次之；跳过最后
        alert.addButton(withTitle: t("import.conflict.keep"))
        alert.addButton(withTitle: t("import.conflict.replace"))
        alert.addButton(withTitle: t("import.conflict.skip"))

        if remainingCount > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = t("import.conflict.applyAll")
        }

        let response = alert.runModal()
        let applyToAll = remainingCount > 1 && alert.suppressionButton?.state == .on

        let action: ImportConflictAction
        switch response {
        case .alertFirstButtonReturn:
            action = .keepRenamed
        case .alertSecondButtonReturn:
            action = .replace
        default:
            action = .skip
        }
        return (action, applyToAll)
    }

    /// 在同级目录生成不冲突的文件/文件夹名：`name.ext` → `name 2.ext` → `name 3.ext` …
    private func makeUniqueSiblingURL(for preferred: URL) -> URL {
        let parent = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let rawBase: String
        if ext.isEmpty {
            rawBase = preferred.lastPathComponent
        } else {
            rawBase = preferred.deletingPathExtension().lastPathComponent
        }
        let baseName = sanitizedImportLeafName(rawBase)

        var index = 2
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = sanitizedImportLeafName("\(baseName) \(index)")
            } else {
                candidateName = sanitizedImportLeafName("\(baseName) \(index).\(ext)")
            }
            let candidate = parent.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
            // 极端兜底，避免死循环
            if index > 10_000 {
                let uuidSuffix = String(UUID().uuidString.prefix(6))
                if ext.isEmpty {
                    return parent.appendingPathComponent(
                        sanitizedImportLeafName("\(baseName) \(uuidSuffix)"),
                        isDirectory: false
                    )
                }
                return parent.appendingPathComponent(
                    sanitizedImportLeafName("\(baseName) \(uuidSuffix).\(ext)"),
                    isDirectory: false
                )
            }
        }
    }

    /// 将源文件/目录落到目标路径。
    /// - 源目标相同：直接返回
    /// - 替换：先完整复制到临时项，再 `replaceItemAt`，避免「先删后拷」中途失败丢原文件
    /// - 保留/新建：目标不应已存在；若竞态下已存在则失败（由上层计为 failed）
    /// - 强制目标与临时项都在 `allowedRoot` 下，防止路径穿越写到库外
    private func placeImportedItem(
        from sourceURL: URL,
        to destURL: URL,
        replacing: Bool,
        allowedRoot: URL
    ) throws {
        let src = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let dst = destURL.resolvingSymlinksInPath().standardizedFileURL
        let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard src != dst else { return }
        guard isURL(dst, strictlyInside: root) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let parent = dst.deletingLastPathComponent()
        guard isURL(parent, strictlyInside: root) || parent.standardizedFileURL == root else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let safeLeaf = sanitizedImportLeafName(dst.lastPathComponent)
        let tempURL = parent.appendingPathComponent(
            ".waifux-import-\(UUID().uuidString)-\(safeLeaf)"
        )
        guard isURL(tempURL, strictlyInside: root) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        do {
            try fileManager.copyItem(at: src, to: tempURL)
            if fileManager.fileExists(atPath: dst.path) {
                guard replacing else {
                    try? fileManager.removeItem(at: tempURL)
                    throw CocoaError(.fileWriteFileExists)
                }
                // 用已复制完成的临时项替换目标，失败时原目标仍保留
                _ = try fileManager.replaceItemAt(
                    dst,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: tempURL, to: dst)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    /// 目标/临时路径必须落在库目录内（含解析符号链接后）。
    private func isURL(_ url: URL, strictlyInside root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        if path == rootPath { return false }
        if rootPath == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(rootPath + "/")
    }

    /// 导入落盘只用文件名叶子；拒绝 `..` / 路径分隔，避免 `appendingPathComponent` 逃逸。
    private func sanitizedImportLeafName(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let slash = name.lastIndex(of: "\\") {
            name = String(name[name.index(after: slash)...])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\\") {
            return "imported-\(UUID().uuidString.prefix(8))"
        }
        return name
    }

    /// 在库根下构造安全目标 URL（仅一层叶子名）。
    private func safeDestinationURL(in folder: URL, preferredLeaf: String) -> URL {
        let leaf = sanitizedImportLeafName(preferredLeaf)
        return folder.appendingPathComponent(leaf, isDirectory: false)
    }

    // MARK: - 壁纸导入

    private func importWallpaper(from sourceURL: URL, folderID: String?) async -> ImportOutcome {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return .failed
        }

        let destinationFolder = downloadPathManager.wallpapersFolderURL
        let preferredURL = safeDestinationURL(
            in: destinationFolder,
            preferredLeaf: sourceURL.lastPathComponent
        )

        guard let resolved = await resolveDestinationURL(
            preferred: preferredURL,
            sourceURL: sourceURL
        ) else {
            return .skipped
        }
        let destURL = resolved.url

        do {
            try placeImportedItem(
                from: sourceURL,
                to: destURL,
                replacing: resolved.shouldReplace,
                allowedRoot: destinationFolder
            )

            let wallpaper = makeImportedWallpaper(from: destURL)
            wallpaperLibrary.recordDownload(wallpaper, fileURL: destURL)

            // 如果指定了文件夹，归入该文件夹（导入只写入下载集合）
            if let folderID {
                wallpaperLibrary.moveWallpaperToFolder(
                    wallpaperID: wallpaper.id,
                    folderID: folderID,
                    scope: .downloads
                )
            }

            return .success
        } catch {
            print("[ImportService] Failed to import wallpaper \(sourceURL.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// 从导入的图片文件创建 Wallpaper 对象
    private func makeImportedWallpaper(from fileURL: URL) -> Wallpaper {
        let fileName = fileURL.lastPathComponent
        let stem = fileURL.deletingPathExtension().lastPathComponent
        // 最终文件名决定库记录 id：保留副本（name 2）时必须与原项区分。
        // wallhaven 原文件名仍尽量取 id；自动重命名副本则用完整 stem，避免覆盖原记录。
        let id: String
        if fileName.hasPrefix("wallhaven-"),
           !Self.hasAutoRenameSuffix(stem),
           let extracted = Self.wallhavenID(fromFileName: fileName),
           !extracted.isEmpty {
            id = extracted
        } else {
            id = "local_import_\(stem)"
        }

        let localPath = fileURL.absoluteString
        var dimensionX = 1920
        var dimensionY = 1080
        if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            if let orientation = properties[kCGImagePropertyOrientation as String] as? UInt32,
               (5...8).contains(orientation) {
                dimensionX = height
                dimensionY = width
            } else {
                dimensionX = width
                dimensionY = height
            }
        }
        let resolution = "\(dimensionX)x\(dimensionY)"
        let ratio = dimensionY > 0 ? Double(dimensionX) / Double(dimensionY) : 1.77

        return Wallpaper(
            id: id,
            title: nil,
            url: localPath,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: nil,
            purity: "sfw",
            category: "general",
            dimensionX: dimensionX,
            dimensionY: dimensionY,
            resolution: resolution,
            ratio: String(format: "%.2f", ratio),
            fileSize: nil,
            fileType: nil,
            createdAt: nil,
            colors: [],
            path: localPath,
            thumbs: Wallpaper.Thumbs(large: localPath, original: localPath, small: localPath),
            tags: nil,
            uploader: nil
        )
    }

    // MARK: - 媒体导入

    private func importMedia(from sourceURL: URL, folderID: String?) async -> ImportOutcome {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return .failed
        }

        let destinationFolder = downloadPathManager.mediaFolderURL
        let preferredURL = safeDestinationURL(
            in: destinationFolder,
            preferredLeaf: sourceURL.lastPathComponent
        )

        guard let resolved = await resolveDestinationURL(
            preferred: preferredURL,
            sourceURL: sourceURL
        ) else {
            return .skipped
        }
        let destURL = resolved.url

        do {
            try placeImportedItem(
                from: sourceURL,
                to: destURL,
                replacing: resolved.shouldReplace,
                allowedRoot: destinationFolder
            )

            let mediaItem = await makeImportedMediaItem(from: destURL)
            mediaLibrary.recordDownload(item: mediaItem, localFileURL: destURL)

            // 如果指定了文件夹，归入该文件夹（导入只写入下载集合）
            if let folderID {
                mediaLibrary.moveMediaToFolder(
                    mediaID: mediaItem.id,
                    folderID: folderID,
                    scope: .downloads
                )
            }

            return .success
        } catch {
            print("[ImportService] Failed to import media \(sourceURL.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// 从导入的视频文件创建 MediaItem 对象
    private func makeImportedMediaItem(from fileURL: URL) async -> MediaItem {
        let fileName = fileURL.lastPathComponent
        let stem = fileURL.deletingPathExtension().lastPathComponent
        // 最终文件名决定库记录 id：保留副本（name 2）时必须与原项区分。
        // motionbgs 原文件名仍尽量取中间 slug，便于与在线下载记录对齐；
        // 一旦是自动重命名副本（stem 以「 数字」结尾），改用完整 stem，避免覆盖原记录。
        let slug: String
        if fileName.hasPrefix("motionbgs-"),
           !Self.hasAutoRenameSuffix(stem),
           let extracted = Self.motionBGSSlug(fromFileName: fileName) {
            slug = extracted
        } else {
            slug = "local_import_\(stem)"
        }

        let title = stem
        var resolutionLabel = t("unknown")
        var durationSeconds: Double?

        let asset = AVAsset(url: fileURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let size = naturalSize.applying(preferredTransform)
                let w = Int(abs(size.width))
                let h = Int(abs(size.height))
                resolutionLabel = "\(w)x\(h)"
            }
            let duration = try await asset.load(.duration)
            if duration.isValid, duration != CMTime.indefinite {
                durationSeconds = CMTimeGetSeconds(duration)
            }
        } catch {
            print("[ImportService] Failed to load video metadata: \(error)")
        }

        // 列表小图与锁屏/桌面高清 poster 分开生成，禁止把 800×600 列表图塞进 posterURL
        _ = await VideoThumbnailCache.shared.thumbnailImage(for: fileURL)
        let listThumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)
        let hdPosterURL = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: fileURL)

        return MediaItem(
            slug: slug,
            title: title,
            pageURL: fileURL,
            thumbnailURL: listThumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("imported"),
            summary: nil,
            previewVideoURL: fileURL,
            posterURL: hdPosterURL ?? listThumbnailURL,
            tags: [],
            exactResolution: resolutionLabel,
            durationSeconds: durationSeconds,
            downloadOptions: [],
            sourceName: t("import"),
            isAnimatedImage: nil
        )
    }

    // MARK: - Workshop 导入

    private func importWorkshop(
        sourceDir: URL,
        projectJSONURL: URL,
        json: [String: Any],
        folderID: String?
    ) async -> ImportOutcome {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return .failed
        }

        let sourceName = sourceDir.lastPathComponent
        let destinationRoot = downloadPathManager.mediaFolderURL

        let title = (json["title"] as? String) ?? sourceName
        // 提取真实 Steam Workshop ID。优先级：
        // 1) WE 规范字段 workshopid（发布到 Workshop 的项目都会写）
        // 2) 兼容本 App 旧版写入的 publishedfileid / id
        // 3) workshopurl 里的 ID（steam://url/CommunityFilePage/<id>）
        // 4) 文件夹名中的纯数字
        // 都拿不到时才用 hash 作为本地 slug，绝不当作真实 Steam ID 拼链接。
        var workshopID = (json["workshopid"] as? String)
            ?? (json["publishedfileid"] as? String)
            ?? (json["id"] as? String)
        workshopID = workshopID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workshopID == nil || workshopID!.isEmpty,
           let rawURL = json["workshopurl"] as? String {
            let urlStr = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlStr.isEmpty, let extracted = Self.extractSteamID(from: urlStr) {
                workshopID = extracted
            }
        }
        if workshopID == nil || workshopID!.isEmpty {
            let numeric = sourceName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if !numeric.isEmpty {
                workshopID = numeric
            }
        }

        // 真实 Steam ID 必须是纯数字；非数字值（如旧版 hash）不能当作 Steam ID
        let realSteamID = workshopID.flatMap { id -> String? in
            !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
        }

        // 本地 slug：有真实 ID 就用，没有就生成稳定的本地 hash（仅用于目录名/去重，不暴露为 Steam 链接）
        let preferredLocalSlug: String
        if let realSteamID {
            preferredLocalSlug = realSteamID
        } else {
            let hash = String(format: "%08x", sourceDir.absoluteString.hashValue & 0xFFFFFFFF)
            preferredLocalSlug = hash.isEmpty ? String(UUID().uuidString.prefix(8)) : hash
            print("[ImportService] Non-numeric folder name '\(sourceName)', using local slug: \(preferredLocalSlug) (no real Steam ID)")
        }

        guard !preferredLocalSlug.isEmpty else {
            print("[ImportService] Could not infer workshop ID for \(sourceName)")
            return .failed
        }

        let preferredDestDir = safeDestinationURL(
            in: destinationRoot,
            preferredLeaf: "workshop_\(preferredLocalSlug)"
        )
        guard let resolved = await resolveDestinationURL(
            preferred: preferredDestDir,
            sourceURL: sourceDir
        ) else {
            return .skipped
        }
        let destDir = resolved.url
        // 目录名去掉 `workshop_` 前缀后作为记录 slug，保证保留副本时 id 不冲突
        let folderName = destDir.lastPathComponent
        let localSlug: String
        if folderName.hasPrefix("workshop_") {
            localSlug = String(folderName.dropFirst("workshop_".count))
        } else {
            localSlug = folderName
        }

        do {
            try placeImportedItem(
                from: sourceDir,
                to: destDir,
                replacing: resolved.shouldReplace,
                allowedRoot: destinationRoot
            )

            let previewURL = findPreview(in: destDir)
            let item = makeImportedWorkshopItem(
                localSlug: localSlug,
                steamID: realSteamID,
                title: title,
                projectJSON: json,
                destDir: destDir,
                previewURL: previewURL
            )
            mediaLibrary.recordDownload(item: item, localFileURL: destDir)

            if let folderID {
                mediaLibrary.moveMediaToFolder(
                    mediaID: item.id,
                    folderID: folderID,
                    scope: .downloads
                )
            }

            return .success
        } catch {
            print("[ImportService] Failed to import workshop \(sourceName): \(error)")
            return .failed
        }
    }

    /// 在指定目录中递归查找预览图
    private func findPreview(in dir: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if isWorkshopPreviewImage(fileURL) {
                return fileURL
            }
        }
        return nil
    }

    private func makeImportedWorkshopItem(
        localSlug: String,
        steamID: String?,
        title: String,
        projectJSON: [String: Any],
        destDir: URL,
        previewURL: URL?
    ) -> MediaItem {
        let typeString = (projectJSON["type"] as? String) ?? "pkg"
        let resolutionLabel = typeString.capitalized
        let thumbnailURL = previewURL ?? URL(string: "https://steamcommunity.com/favicon.ico")!

        // 只有拿到真实纯数字 Steam ID 时才生成 Steam 链接；
        // 否则用本地导入目录 file URL，避免把本地 hash/UUID 伪造成打不开的 Steam URL。
        let pageURL: URL
        if let steamID {
            pageURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(steamID)")!
        } else {
            pageURL = destDir
        }

        return MediaItem(
            slug: "workshop_\(localSlug)",
            title: title,
            pageURL: pageURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("workshop"),
            summary: (projectJSON["description"] as? String),
            previewVideoURL: nil,
            posterURL: previewURL,
            tags: [],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: t("wallpaperEngine"),
            isAnimatedImage: nil
        )
    }

    /// 是否为导入「保留」产生的自动重命名后缀：`name 2` / `name 3` …
    private static func hasAutoRenameSuffix(_ stem: String) -> Bool {
        stem.range(of: #" \d+$"#, options: .regularExpression) != nil
    }

    /// `wallhaven-<id>.ext` → id
    private static func wallhavenID(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix("wallhaven-"),
              let dotIndex = fileName.firstIndex(of: ".") else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: 10)
        guard start < dotIndex else { return nil }
        return String(fileName[start..<dotIndex])
    }

    /// `motionbgs-<slug>-...ext` → slug
    private static func motionBGSSlug(fromFileName fileName: String) -> String? {
        let parts = fileName.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let slug = String(parts[1])
        return slug.isEmpty ? nil : slug
    }

    /// 从 Steam 链接里提取 Workshop ID，支持：
    /// - https://steamcommunity.com/sharedfiles/filedetails/?id=3741983456
    /// - steam://url/CommunityFilePage/3741983456
    /// - 纯数字
    private static func extractSteamID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return trimmed }

        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let path = components.path.lowercased()
        // https 形式：取 query 的 id
        if path.contains("sharedfiles/filedetails") {
            return components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
        }

        // steam://url/CommunityFilePage/<id> 形式：取最后一段路径
        if trimmed.lowercased().hasPrefix("steam://"),
           path.contains("communityfilepage") {
            return path.split(separator: "/").last.map(String.init)
        }

        return nil
    }

    // MARK: - 文件类型判断

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"].contains(ext)
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv"].contains(ext)
    }
}
