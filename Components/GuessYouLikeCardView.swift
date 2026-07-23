import SwiftUI
import Kingfisher
import AppKit

// MARK: - 光标追踪视图（不阻塞滚动）
/// 替代 .onContinuousHover：通过 NSTrackingArea 追踪光标位置，
/// 同时将 scrollWheel 事件转发给父级 NSScrollView，避免卡片拦截滚动。
private struct CursorTrackingView: NSViewRepresentable {
    let onCursorMove: (CGPoint) -> Void
    let onCursorEnter: () -> Void
    let onCursorExit: () -> Void

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.onCursorMove = onCursorMove
        view.onCursorEnter = onCursorEnter
        view.onCursorExit = onCursorExit
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.onCursorMove = onCursorMove
        nsView.onCursorEnter = onCursorEnter
        nsView.onCursorExit = onCursorExit
    }
}

private class CursorTrackingNSView: NSView {
    var onCursorMove: ((CGPoint) -> Void)?
    var onCursorEnter: (() -> Void)?
    var onCursorExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onCursorEnter?()
        onCursorMove?(local)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onCursorMove?(local)
    }

    override func mouseExited(with event: NSEvent) {
        onCursorExit?()
    }

    /// 将滚动事件转发给父级 NSScrollView，避免卡片拦截滚动
    override func scrollWheel(with event: NSEvent) {
        var view: NSView? = superview
        while let v = view {
            if let scrollView = v as? NSScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            view = v.superview
        }
        // 找不到 ScrollView 时走默认路径
        super.scrollWheel(with: event)
    }
}

// MARK: - 猜你喜欢单张卡片

struct GuessYouLikeCardView: View {
    let item: GuessYouLikeItem
    let onDetail: (GuessYouLikeItem) -> Void
    let onDownload: (GuessYouLikeItem) -> Void

    @State private var hoverLocation: CGPoint = .zero
    @State private var isHovering: Bool = false

    private let maxTiltAngle: CGFloat = 6
    // 固定卡片尺寸
    private let cardW: CGFloat = 260
    private let cardH: CGFloat = 360

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .overlay(coverImage)
                .overlay(contentOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )

            // ⚡ 光标追踪层：替代 .onContinuousHover，转发滚动事件给 ScrollView
            CursorTrackingView(
                onCursorMove: { location in
                    // NSView 坐标系左下角原点 → 转换为 SwiftUI 左上角原点
                    let converted = CGPoint(x: location.x, y: cardH - location.y)
                    hoverLocation = converted
                },
                onCursorEnter: {
                    isHovering = true
                },
                onCursorExit: {
                    isHovering = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        hoverLocation = .zero
                    }
                }
            )
        }
        .frame(width: cardW, height: cardH)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .rotation3DEffect(rotationY, axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        .rotation3DEffect(rotationX, axis: (x: 1, y: 0, z: 0), perspective: 0.3)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    // MARK: - 内容层

    @ViewBuilder
    private var contentOverlay: some View {
        ZStack(alignment: .bottom) {
            // 底部渐变遮罩
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.7)]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                // 顶部：来源标签 + 标题 + 详情按钮
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 来源标签
                        sourceTag
                        // 标题
                        Text(item.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        Text(item.subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Spacer()
                    // 右上角液态玻璃圆形按钮 → 跳转详情
                    Button { onDetail(item) } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                // 底部：独立下载按钮（带边距，不延伸两边）
                Button { onDownload(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t("download"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 来源标签

    @ViewBuilder
    private var sourceTag: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sourceColor.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(item.sourceName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(.black.opacity(0.45))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var sourceColor: Color {
        switch item.sourceName {
        case "WallHaven": return Color(hex: "FF6B6B")
        case "4K Wallpapers": return Color(hex: "4ECDC4")
        case "MotionBG": return Color(hex: "45B7D1")
        case "Wallpaper Engine": return Color(hex: "96CEB4")
        case "DongTai": return Color(hex: "F472B6")
        case "Wallsflow": return Color(hex: "9B5DE5")
        default: return Color(hex: "DDA0DD")
        }
    }

    // MARK: - 封面图

    @ViewBuilder
    private var coverImage: some View {
        if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
            KFImage(url)
                .memoryCacheExpiration(.seconds(300))
                .placeholder { Color.black.opacity(0.3) }
                .fade(duration: 0.2)
                .resizable()
                .downsampling(size: CGSize(width: cardW * 2, height: cardH * 2))
                .aspectRatio(contentMode: .fill)
        }
    }

    // MARK: - 悬停倾斜（使用固定尺寸，避免 GeometryReader 开销）

    private var rotationY: Angle {
        guard isHovering else { return .zero }
        let nx = (hoverLocation.x / cardW - 0.5) * 2
        return .degrees(Double(nx * maxTiltAngle))
    }

    private var rotationX: Angle {
        guard isHovering else { return .zero }
        let ny = -(hoverLocation.y / cardH - 0.5) * 2
        return .degrees(Double(ny * maxTiltAngle))
    }
}

// MARK: - 预览

#Preview {
    GuessYouLikeCardView(
        item: GuessYouLikeItem.mockItems()[0],
        onDetail: { _ in },
        onDownload: { _ in }
    )
    .frame(width: 220, height: 310)
    .padding(40)
    .background(Color(hex: "0D0D0D"))
}
