import SwiftUI

// MARK: - 导入进度弹窗

struct ImportProgressView: View {
    @StateObject private var importService = ImportService.shared
    @Binding var isPresented: Bool
    /// 可选：导入完成后的回调
    var onComplete: ((ImportResult) -> Void)?

    @State private var showResult = false
    @State private var lastResult: ImportResult?

    private let accentColor = LiquidGlassColors.accentCyan
    private let successColor = Color.green
    private let failColor = Color.red

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            headerView
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            // 进度内容
            if importService.isImporting || importService.progress.isCancelled {
                importingContent
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else if showResult, let result = lastResult {
                resultContent(result)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .onChange(of: importService.isImporting) { _, isImporting in
            if !isImporting, importService.progress.isFinished {
                let result = ImportResult(
                    totalFiles: importService.progress.totalFiles,
                    successfulImports: importService.progress.successfulImports,
                    failedImports: importService.progress.failedImports,
                    skippedImports: importService.progress.skippedImports
                )
                showResult = true
                lastResult = result
                onComplete?(result)
            }
        }
        .onAppear {
            // 如果导入已经完成（例如从 sheet 外部完成了），直接显示结果
            if !importService.isImporting, importService.progress.isFinished {
                let result = ImportResult(
                    totalFiles: importService.progress.totalFiles,
                    successfulImports: importService.progress.successfulImports,
                    failedImports: importService.progress.failedImports,
                    skippedImports: importService.progress.skippedImports
                )
                showResult = true
                lastResult = result
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(importService.isImporting ? t("import.in.progress") : t("import.completed"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))

                Text(importService.isImporting
                     ? String(format: t("import.processing.count"), importService.progress.completedFiles, importService.progress.totalFiles)
                     : t("import.result.summary"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            if importService.isImporting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
            } else if showResult, let result = lastResult {
                Image(systemName: result.allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(result.allSucceeded ? successColor : .orange)
            }
        }
    }

    // MARK: - 导入中

    private var importingContent: some View {
        VStack(spacing: 16) {
            // 当前文件名
            if !importService.progress.currentFileName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))

                    Text(importService.progress.currentFileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeOut(duration: 0.15), value: importService.progress.currentFileName)
            }

            // 进度条
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor, accentColor.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * importService.progress.fractionCompleted, height: 8)
                            .animation(.easeOut(duration: 0.2), value: importService.progress.fractionCompleted)
                    }
                }
                .frame(height: 8)

                // 百分比 + 计数
                HStack {
                    Text("\(Int(importService.progress.fractionCompleted * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accentColor.opacity(0.9))

                    Spacer()

                    if importService.progress.successfulImports > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("\(importService.progress.successfulImports)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(successColor.opacity(0.8))
                    }

                    if importService.progress.failedImports > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                            Text("\(importService.progress.failedImports)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(failColor.opacity(0.8))
                        .padding(.leading, 8)
                    }
                }
            }

            // 取消按钮
            if importService.isImporting {
                Button {
                    importService.cancel()
                } label: {
                    Text(t("cancel"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 结果

    private func resultContent(_ result: ImportResult) -> some View {
        VStack(spacing: 16) {
            // 摘要统计
            HStack(spacing: 24) {
                statBadge(
                    value: result.successfulImports,
                    label: t("import.success"),
                    icon: "checkmark.circle.fill",
                    color: successColor
                )

                statBadge(
                    value: result.failedImports,
                    label: t("import.failed"),
                    icon: "xmark.circle.fill",
                    color: result.failedImports > 0 ? failColor : .white.opacity(0.3)
                )

                statBadge(
                    value: result.totalFiles,
                    label: t("import.total"),
                    icon: "doc.fill",
                    color: .white.opacity(0.6)
                )
            }

            // 关闭按钮
            Button {
                isPresented = false
            } label: {
                Text(t("done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor.opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(accentColor.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func statBadge(value: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(color)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(minWidth: 70)
    }
}

// MARK: - 导入进度管理视图（带启动与关闭逻辑）

/// 提供一个便捷的 `.sheet` 绑定，自动管理导入状态
struct ImportSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onComplete: ((ImportResult) -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                ImportProgressView(isPresented: $isPresented, onComplete: onComplete)
            }
    }
}

extension View {
    func importProgressSheet(isPresented: Binding<Bool>, onComplete: ((ImportResult) -> Void)? = nil) -> some View {
        modifier(ImportSheetModifier(isPresented: isPresented, onComplete: onComplete))
    }
}
