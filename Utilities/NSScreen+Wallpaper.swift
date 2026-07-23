import AppKit
import CoreGraphics

enum WallpaperScreenIdentity {
    static func fingerprint(legacyFingerprint: String, hasHardwareSerial: Bool, position: CGPoint) -> String {
        guard !hasHardwareSerial else { return legacyFingerprint }
        return "\(legacyFingerprint):position:\(Int(position.x.rounded()))x\(Int(position.y.rounded()))"
    }

    /// `NSScreen.screens` 的系统顺序在睡眠/唤醒、重插、分辨率协商后可能打乱。
    /// 用「主屏优先 + 从左到右 + 从上到下 + 稳定 id」生成跨进程一致的展示/CLI 索引顺序。
    static func orderedScreens(_ screens: [NSScreen]) -> [NSScreen] {
        let mainID = NSScreen.main?.wallpaperScreenIdentifier
        return screens.sorted { lhs, rhs in
            let lhsIsMain = lhs.wallpaperScreenIdentifier == mainID
            let rhsIsMain = rhs.wallpaperScreenIdentifier == mainID
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }

            let lx = lhs.frame.origin.x
            let rx = rhs.frame.origin.x
            if abs(lx - rx) > 0.5 {
                return lx < rx
            }

            let ly = lhs.frame.origin.y
            let ry = rhs.frame.origin.y
            if abs(ly - ry) > 0.5 {
                // AppKit 坐标 y 向上；maxY 更大的屏更靠上，用户感知上应排在前面。
                return lhs.frame.maxY > rhs.frame.maxY
            }

            return lhs.wallpaperScreenIdentifier < rhs.wallpaperScreenIdentifier
        }
    }

    static func stableIndex(of screen: NSScreen, in screens: [NSScreen]? = nil) -> Int? {
        let ordered = orderedScreens(screens ?? NSScreen.screens)
        return ordered.firstIndex {
            $0.wallpaperScreenIdentifier == screen.wallpaperScreenIdentifier
        }
    }
}

extension NSScreen {
    /// 跨模块统一的稳定屏幕顺序（设置页「显示器 N」、选择弹窗、CLI 索引共用）。
    static var screensOrderedForDisplay: [NSScreen] {
        WallpaperScreenIdentity.orderedScreens(NSScreen.screens)
    }

    /// 返回稳定的屏幕标识符，用于跨模块的屏幕级状态字典 key。
    ///
    /// 优先使用 `NSScreenNumber`（CGDirectDisplayID 的字符串形式），它在同一物理显示器
    /// 的同一端口上具有全局唯一性和稳定性。
    ///
    /// 当 `NSScreenNumber` 不可用时（某些外接显示器、AirPlay 屏幕等），
    /// 回退到 `localizedName + 原点坐标`，比单纯的 localizedName 更能区分
    /// 同型号的多块显示器。
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }

    var isBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(screenNumber.uint32Value)) != 0
    }

    /// 热插拔检测使用的连接指纹。不要包含分辨率/缩放/位置，否则外接屏刚接入时
    /// macOS 的模式协商或用户重排桌面时会把同一块显示器误判成新连接。
    var externalConnectionFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName)"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(builtin)"
    }

    /// 调度器配置使用的物理显示器指纹。
    ///
    /// 必须能区分同型号、无硬件序列号的多块外接屏；否则 sleep/wake 后
    /// `NSScreenNumber` 变化时配置会互相串台（设置页「显示器 2/3」对调）。
    /// 有序列号时复用连接指纹；无序列号时与 `wallpaperScreenFingerprint` 一致，
    /// 用桌面排列位置拆开。
    var schedulerConfigFingerprint: String {
        wallpaperScreenFingerprint
    }

    /// 旧版显示器指纹格式，仅用于迁移已保存的状态。
    ///
    /// 无硬件序列号的同型号显示器在旧格式下会共享同一指纹，不能再用于新的持久化键。
    var legacyWallpaperScreenFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName):\(Int(frame.width))x\(Int(frame.height))"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"
        let pixelWidth = Int(frame.width * backingScaleFactor)
        let pixelHeight = Int(frame.height * backingScaleFactor)

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(pixelWidth)x\(pixelHeight):\(builtin)"
    }

    /// 尽量稳定的物理显示器指纹，用于外接屏断开 / 重连后 `NSScreenNumber` 变化时找回目标屏。
    ///
    /// 当显示器未提供硬件序列号时，厂商/型号/分辨率不足以区分两块同型号屏幕。
    /// 加入桌面排列位置可在重启后的相同显示器布局中保留独立恢复记录。
    var wallpaperScreenFingerprint: String {
        let legacyFingerprint = legacyWallpaperScreenFingerprint
        let hasHardwareSerial: Bool
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            hasHardwareSerial = CGDisplaySerialNumber(CGDirectDisplayID(screenNumber.uint32Value)) != 0
        } else {
            hasHardwareSerial = false
        }
        return WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: legacyFingerprint,
            hasHardwareSerial: hasHardwareSerial,
            position: frame.origin
        )
    }

    /// 用于把历史 fingerprint 映射回当前屏（含旧版无 position 的短指纹）。
    var schedulerFingerprintCandidates: [String] {
        let result = [
            wallpaperScreenFingerprint,
            schedulerConfigFingerprint,
            legacyWallpaperScreenFingerprint,
            externalConnectionFingerprint,
        ]
        // 去重但保序
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// 当前显示器的主刷新率（Hz），取整。
    ///
    /// 通过 `CGDisplayCopyDisplayMode` 获取当前分辨率模式的刷新率。
    /// ProMotion / 可变刷新率显示器可能返回 0，此时回退到 60。
    var maxRefreshRate: Int {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 60
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 60
        }
        let rate = mode.refreshRate
        // ProMotion / 可变刷新率可能返回 0
        if rate <= 0 {
            return 60
        }
        return Int(rate.rounded())
    }
}
