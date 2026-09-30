import AppServices
import DesignSystem
import MediaSourceAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class LibraryAudioConversionViewModel {
    let service: any LibraryConversionServing
    let scope: LibraryConversionScope

    var target: AudioConversionTarget
    private(set) var preflight: LibraryConversionPreflight?
    private(set) var batches: [LibraryConversionBatchSnapshot] = []
    private(set) var isPreflighting = false
    private(set) var isStarting = false
    private(set) var failureMessage: String?
    var isStartConfirmationPresented = false

    init(
        service: any LibraryConversionServing,
        scope: LibraryConversionScope,
        initialTarget: AudioConversionTarget
    ) {
        self.service = service
        self.scope = scope
        target = initialTarget
    }

    func setTarget(_ value: AudioConversionTarget) {
        guard target != value else { return }
        target = value
        preflight = nil
        failureMessage = nil
    }

    func observe() async {
        batches = await service.snapshots()
        let stream = await service.makeEventStream()
        for await event in stream {
            guard !Task.isCancelled else { return }
            switch event {
            case .updated(let snapshot):
                upsert(snapshot)
            }
        }
    }

    func runPreflight() async {
        guard !isPreflighting, !isStarting else { return }
        isPreflighting = true
        failureMessage = nil
        defer { isPreflighting = false }
        do {
            preflight = try await service.preflight(scope: scope, target: target)
        } catch is CancellationError {
            return
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func requestStart() {
        guard preflight?.eligibleAssetCount ?? 0 > 0 else { return }
        isStartConfirmationPresented = true
    }

    func startConversion() async {
        guard !isStarting, preflight?.eligibleAssetCount ?? 0 > 0 else { return }
        isStarting = true
        failureMessage = nil
        defer { isStarting = false }
        do {
            let id = try await service.start(scope: scope, target: target)
            if let snapshot = await service.snapshot(id: id) {
                upsert(snapshot)
            }
            preflight = nil
        } catch is CancellationError {
            return
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func pause(_ id: UUID) async {
        await service.pause(id: id)
        await refresh(id)
    }

    func resume(_ id: UUID) async {
        await service.resume(id: id)
        await refresh(id)
    }

    func cancel(_ id: UUID) async {
        await service.cancel(id: id)
        await refresh(id)
    }

    func retryFailures(_ id: UUID) async {
        failureMessage = nil
        do {
            let retryID = try await service.retryFailures(id: id)
            if let snapshot = await service.snapshot(id: retryID) {
                upsert(snapshot)
            }
        } catch is CancellationError {
            return
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    private func refresh(_ id: UUID) async {
        if let snapshot = await service.snapshot(id: id) {
            upsert(snapshot)
        }
    }

    private func upsert(_ snapshot: LibraryConversionBatchSnapshot) {
        if let index = batches.firstIndex(where: { $0.id == snapshot.id }) {
            batches[index] = snapshot
        } else {
            batches.append(snapshot)
        }
        batches.sort { $0.createdAt > $1.createdAt }
    }
}

public struct LibraryAudioConversionView: View {
    @State private var model: LibraryAudioConversionViewModel

    public init(
        service: any LibraryConversionServing,
        scope: LibraryConversionScope,
        initialTarget: AudioConversionTarget = .defaultAAC
    ) {
        _model = State(initialValue: LibraryAudioConversionViewModel(
            service: service,
            scope: scope,
            initialTarget: initialTarget
        ))
    }

    public var body: some View {
        @Bindable var model = model

        Form {
            Section(L("输出")) {
                Picker(L("转换格式"), selection: Binding(
                    get: { model.target },
                    set: { model.setTarget($0) }
                )) {
                    Text(L("ALAC（无损）"))
                        .tag(AudioConversionTarget.alac)
                    ForEach(AACLCBitRate.allCases, id: \.self) { bitRate in
                        Text("AAC-LC \(bitRate.kilobitsPerSecond) kbps")
                            .tag(AudioConversionTarget.aacLC(bitRate))
                    }
                }

                Text(L("转换只处理 App 管理的本地无损音频。共享同一文件的 CUE 歌曲会一起更新，原歌曲资料、收藏和播放记录会保留。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

                Button {
                    Task { await model.runPreflight() }
                } label: {
                    if model.isPreflighting {
                        ProgressView()
                    } else {
                        Label(L("分析可转换项目"), systemImage: "doc.text.magnifyingglass")
                    }
                }
                .disabled(model.isPreflighting || model.isStarting)
                .accessibilityIdentifier("libraryConversion.preflight")
            }

            if let preflight = model.preflight {
                preflightSection(preflight)
            }

            if let failureMessage = model.failureMessage {
                Section(L("状态")) {
                    Label(failureMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MusicFreeColorTokens.warning)
                }
            }

            if !model.batches.isEmpty {
                Section(L("转换任务")) {
                    ForEach(model.batches) { snapshot in
                        batchRow(snapshot)
                    }
                }
            }
        }
        .navigationTitle(L("转换已有资料库"))
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .task { await model.observe() }
        .confirmationDialog(
            L("开始转换？"),
            isPresented: $model.isStartConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("开始转换")) {
                Task { await model.startConversion() }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("每个成功转换的物理文件会替换资料库中的旧文件；失败或取消的项目继续使用原文件。正在播放的旧文件会在播放释放后再清理。"))
        }
    }

    @ViewBuilder
    private func preflightSection(_ preflight: LibraryConversionPreflight) -> some View {
        Section(L("分析结果")) {
            LabeledContent(L("可转换文件"), value: "\(preflight.eligibleAssetCount)")
            LabeledContent(L("受影响歌曲"), value: "\(preflight.eligibleItemCount)")
            LabeledContent(L("跳过文件"), value: "\(preflight.skippedAssetCount)")
            LabeledContent(
                L("原文件大小"),
                value: formattedBytes(preflight.sourceByteCount)
            )
            if let estimated = preflight.estimatedOutputByteCount {
                LabeledContent(L("预计输出大小"), value: formattedBytes(estimated))
            }

            Button {
                model.requestStart()
            } label: {
                if model.isStarting {
                    ProgressView()
                } else {
                    Label(L("开始转换"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(preflight.eligibleAssetCount == 0 || model.isStarting)
            .accessibilityIdentifier("libraryConversion.start")
        }
    }

    @ViewBuilder
    private func batchRow(_ snapshot: LibraryConversionBatchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            HStack {
                Text(snapshot.target.displayName)
                    .font(MusicFreeTypographyTokens.body)
                Spacer()
                Text(snapshot.state.displayName)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            ProgressView(value: progressFraction(snapshot))

            Text(L("完成 %d · 跳过 %d · 失败 %d · 取消 %d",
                   snapshot.completedAssetCount,
                   snapshot.skippedAssetCount,
                   snapshot.failedAssetCount,
                   snapshot.cancelledAssetCount))
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            HStack(spacing: MusicFreeSpacingTokens.small) {
                switch snapshot.state {
                case .queued, .running:
                    Button {
                        Task { await model.pause(snapshot.id) }
                    } label: {
                        Label(L("暂停"), systemImage: "pause.fill")
                    }
                    Button(role: .destructive) {
                        Task { await model.cancel(snapshot.id) }
                    } label: {
                        Label(L("取消"), systemImage: "xmark")
                    }
                case .paused:
                    Button {
                        Task { await model.resume(snapshot.id) }
                    } label: {
                        Label(L("继续"), systemImage: "play.fill")
                    }
                    Button(role: .destructive) {
                        Task { await model.cancel(snapshot.id) }
                    } label: {
                        Label(L("取消"), systemImage: "xmark")
                    }
                case .completed, .cancelled:
                    if snapshot.failedAssetCount > 0 {
                        Button {
                            Task { await model.retryFailures(snapshot.id) }
                        } label: {
                            Label(L("重试失败项"), systemImage: "arrow.clockwise")
                        }
                    }
                case .cancelling:
                    ProgressView()
                }
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryConversion.batch.\(snapshot.id.uuidString)")
    }

    private func progressFraction(_ snapshot: LibraryConversionBatchSnapshot) -> Double {
        guard snapshot.totalAssetCount > 0 else { return 1 }
        let completed = Double(snapshot.processedAssetCount)
        let running = snapshot.currentProgress.values.compactMap(\.fractionCompleted).reduce(0, +)
        return min(1, (completed + running) / Double(snapshot.totalAssetCount))
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private extension AudioConversionTarget {
    var displayName: String {
        switch self {
        case .alac:
            return L("ALAC（无损）")
        case .aacLC(let bitRate):
            return "AAC-LC \(bitRate.kilobitsPerSecond) kbps"
        }
    }
}

private extension LibraryConversionBatchState {
    var displayName: String {
        switch self {
        case .queued: L("等待中")
        case .running: L("转换中")
        case .paused: L("已暂停")
        case .cancelling: L("正在取消")
        case .completed: L("已完成")
        case .cancelled: L("已取消")
        }
    }
}
