import DesignSystem
import MediaSourceAPI
import SwiftUI

public enum LibraryImportProgressPhase: String, Equatable, Sendable {
    case discovered
    case hashing
    case probing
    case copying
    case persisting

    public init(_ phase: MediaImportPhase) {
        switch phase {
        case .discovered: self = .discovered
        case .hashing: self = .hashing
        case .probing: self = .probing
        case .copying: self = .copying
        case .persisting: self = .persisting
        }
    }

    public var title: String {
        switch self {
        case .discovered: return L("已发现")
        case .hashing: return L("正在检查")
        case .probing: return L("正在解析")
        case .copying: return L("正在复制")
        case .persisting: return L("正在保存")
        }
    }
}

public struct LibraryImportFailure: Equatable, Sendable {
    public let itemName: String
    public let code: String
    public let message: String

    public init(itemName: String, code: String, message: String) {
        self.itemName = itemName
        self.code = code
        self.message = message
    }
}

public struct ImportProgressSnapshot: Equatable, Sendable {
    public let importID: UUID
    public let totalItems: Int
    public var processedItems: Int
    public var failedItems: Int
    public var phase: LibraryImportProgressPhase?
    public var currentItemName: String?
    public var failures: [LibraryImportFailure]
    public var result: MediaImportResult?

    public init(importID: UUID, totalItems: Int) {
        self.importID = importID
        self.totalItems = max(0, totalItems)
        self.processedItems = 0
        self.failedItems = 0
        self.phase = nil
        self.currentItemName = nil
        self.failures = []
        self.result = nil
    }
}

public enum LibraryImportState: Equatable, Sendable {
    case idle
    case importing(ImportProgressSnapshot)
    case cancelling(ImportProgressSnapshot)
    case completed(MediaImportResult)
    case failed(String)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var progress: ImportProgressSnapshot? {
        switch self {
        case .importing(let progress), .cancelling(let progress): return progress
        case .idle, .completed, .failed: return nil
        }
    }
}

/// Converts API import events into presentation-safe state without retaining URLs.
public enum ImportEventMapper {
    public static func initialSnapshot(for request: MediaImportRequest) -> ImportProgressSnapshot {
        ImportProgressSnapshot(importID: request.importID, totalItems: request.urls.count)
    }

    public static func apply(
        _ event: MediaImportEvent,
        to snapshot: ImportProgressSnapshot
    ) -> ImportProgressSnapshot {
        guard event.importID == snapshot.importID else { return snapshot }

        var next = snapshot
        switch event {
        case .discovered(_, let url):
            next.phase = .discovered
            next.currentItemName = displayName(for: url)
        case .hashing(_, let url):
            next.phase = .hashing
            next.currentItemName = displayName(for: url)
        case .probing(_, let url):
            next.phase = .probing
            next.currentItemName = displayName(for: url)
        case .copying(_, let url):
            next.phase = .copying
            next.currentItemName = displayName(for: url)
        case .persisting:
            next.phase = .persisting
            next.currentItemName = nil
            next.processedItems = min(next.totalItems, next.processedItems + 1)
        case .itemFailed(_, let url, let error):
            next.currentItemName = nil
            next.failedItems += 1
            next.processedItems = min(next.totalItems, max(next.processedItems + 1, next.failedItems))
            next.failures.append(
                LibraryImportFailure(
                    itemName: displayName(for: url),
                    code: error.diagnosticCode,
                    message: error.userFacingReason
                )
            )
        case .completed(_, let result), .cancelled(_, let result):
            next.phase = nil
            next.currentItemName = nil
            next.processedItems = min(next.totalItems, result.totalItems)
            next.failedItems = result.failed
            next.result = result
        }
        return next
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L("未命名媒体") : name
    }
}

struct ImportProgressView: View {
    let state: LibraryImportState
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.medium) {
            content
        }
        .padding(MusicFreeSpacingTokens.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MusicFreeLayoutMetrics.artworkCornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, MusicFreeSpacingTokens.small)
        .padding(.bottom, MusicFreeSpacingTokens.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .importing(let progress):
            progressContent(progress, isCancelling: false)
        case .cancelling(let progress):
            progressContent(progress, isCancelling: true)
        case .completed(let result):
            resultContent(result)
        case .failed(let message):
            ErrorStateView(title: L("import.failed.title"), message: message, retryTitle: L("关闭"), retry: dismiss)
        }
    }

    @ViewBuilder
    private func progressContent(
        _ progress: ImportProgressSnapshot,
        isCancelling: Bool
    ) -> some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            ProgressView()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(isCancelling ? L("正在取消导入") : L("正在导入媒体"))
                    .font(MusicFreeTypographyTokens.sectionTitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                if let phase = progress.phase {
                    Text(phase.title)
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }
            Spacer(minLength: 0)
            if !isCancelling {
                Button(action: cancel) {
                    Label(L("取消"), systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .help(L("取消导入"))
            }
        }

        if progress.totalItems > 0 {
            ProgressView(
                value: Double(progress.processedItems),
                total: Double(progress.totalItems)
            )
            .tint(MusicFreeColorTokens.accent)
            .accessibilityValue(
                Text(L("已处理 %d，共 %d", progress.processedItems, progress.totalItems))
            )
        }

        if let currentItemName = progress.currentItemName, !currentItemName.isEmpty {
            Text(currentItemName)
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                .lineLimit(1)
        }

        failureList(progress.failures)
    }

    @ViewBuilder
    private func resultContent(_ result: MediaImportResult) -> some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            Image(systemName: result.isCancelled ? "pause.circle" : "checkmark.circle")
                .foregroundStyle(result.isCancelled ? MusicFreeColorTokens.warning : MusicFreeColorTokens.positive)
                .accessibilityHidden(true)
            Text(result.isCancelled ? L("导入已取消") : L("导入完成"))
                .font(MusicFreeTypographyTokens.sectionTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Label(L("关闭"), systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .help(L("关闭导入结果"))
        }

        summary(result)
    }

    @ViewBuilder
    private func summary(_ result: MediaImportResult) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            if result.imported > 0 { Text(L("已导入 %d 首", result.imported)) }
            if result.duplicate > 0 { Text(L("重复 %d 首", result.duplicate)) }
            if result.skipped > 0 { Text(L("已跳过 %d 首", result.skipped)) }
            if result.failed > 0 { Text(L("失败 %d 首", result.failed)) }
            if result.cancelled > 0 { Text(L("取消 %d 首", result.cancelled)) }
        }
        .font(MusicFreeTypographyTokens.secondary)
        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
    }

    @ViewBuilder
    private func failureList(_ failures: [LibraryImportFailure]) -> some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(L("部分项目未导入"))
                    .font(MusicFreeTypographyTokens.secondary.weight(.semibold))
                ForEach(Array(failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                    Text(L("format.colonPair", failure.itemName, failure.message))
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .lineLimit(2)
                }
                if failures.count > 3 {
                    Text(L("还有 %d 项失败", failures.count - 3))
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                }
            }
        }
    }
}
