import AppServices
import DesignSystem
import Foundation
import MediaSourceAPI
import Observation
import UIKit

/// Native presentation for conversion initiated from the UIKit library route.
@MainActor public final class LibraryAudioConversionViewController: UITableViewController {
    private enum Row {
        case target, preflight, start, detail(String, String), failure(String)
        case batch(LibraryConversionBatchSnapshot), pause(UUID), resume(UUID), cancel(UUID), retry(UUID)
    }
    private struct Section { let title: String; let rows: [Row] }
    private let model: LibraryAudioConversionViewModel
    private var sections: [Section] = []
    private var observationTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    public init(service: any LibraryConversionServing, scope: LibraryConversionScope,
                initialTarget: AudioConversionTarget = .defaultAAC) {
        model = LibraryAudioConversionViewModel(service: service, scope: scope, initialTarget: initialTarget)
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { observationTask?.cancel(); operationTask?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L("转换已有资料库")
        view.accessibilityIdentifier = "libraryConversion.form"
        render()
        let model = model
        observationTask = Task { await model.observe() }
    }

    private func render() {
        sections = [.init(title: L("输出"), rows: [.target, .preflight])]
        if let preflight = model.preflight {
            var rows: [Row] = [.detail(L("可转换文件"), "\(preflight.eligibleAssetCount)"),
                .detail(L("受影响歌曲"), "\(preflight.eligibleItemCount)"),
                .detail(L("跳过文件"), "\(preflight.skippedAssetCount)"),
                .detail(L("原文件大小"), bytes(preflight.sourceByteCount))]
            if let estimate = preflight.estimatedOutputByteCount { rows.append(.detail(L("预计输出大小"), bytes(estimate))) }
            rows.append(.start)
            sections.append(.init(title: L("分析结果"), rows: rows))
        }
        if let failure = model.failureMessage { sections.append(.init(title: L("状态"), rows: [.failure(failure)])) }
        for batch in model.batches {
            var rows: [Row] = [.batch(batch)]
            switch batch.state {
            case .queued, .running: rows += [.pause(batch.id), .cancel(batch.id)]
            case .paused: rows += [.resume(batch.id), .cancel(batch.id)]
            case .completed, .cancelled: if batch.failedAssetCount > 0 { rows.append(.retry(batch.id)) }
            case .cancelling: break
            }
            sections.append(.init(title: L("转换任务"), rows: rows))
        }
        tableView.reloadData()
        withObservationTracking {
            _ = model.target; _ = model.preflight; _ = model.batches
            _ = model.isPreflighting; _ = model.isStarting; _ = model.failureMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? L("转换只处理 App 管理的本地无损音频。共享同一文件的 CUE 歌曲会一起更新，原歌曲资料、收藏和播放记录会保留。") : nil
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        let busy = model.isPreflighting || model.isStarting
        switch sections[indexPath.section].rows[indexPath.row] {
        case .target:
            content.text = L("转换格式")
            let button = UIButton(type: .system)
            button.setTitle(targetName(model.target), for: .normal)
            button.showsMenuAsPrimaryAction = true; button.isEnabled = !busy
            button.menu = UIMenu(children: ([AudioConversionTarget.alac] + AACLCBitRate.allCases.map { .aacLC($0) }).map { target in
                UIAction(title: targetName(target), state: target == model.target ? .on : .off) { [weak self] _ in self?.model.setTarget(target) }
            })
            button.sizeToFit(); button.accessibilityIdentifier = "libraryConversion.target"
            cell.accessoryView = button
        case .preflight:
            content.text = L("分析可转换项目"); content.image = UIImage(systemName: "doc.text.magnifyingglass")
            cell.accessibilityIdentifier = "libraryConversion.preflight"; cell.isUserInteractionEnabled = !busy
            content.textProperties.color = busy ? .secondaryLabel : .systemBlue
        case .start:
            content.text = L("开始转换"); content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            cell.accessibilityIdentifier = "libraryConversion.start"
            cell.isUserInteractionEnabled = !busy && (model.preflight?.eligibleAssetCount ?? 0) > 0
            content.textProperties.color = cell.isUserInteractionEnabled ? .systemBlue : .secondaryLabel
        case .detail(let title, let value): content.text = title; content.secondaryText = value; cell.selectionStyle = .none
        case .failure(let failure): content.text = failure; content.textProperties.color = .systemRed; cell.selectionStyle = .none
        case .batch(let batch):
            content.text = "\(targetName(batch.target)) · \(stateName(batch.state))"
            let progress = batch.totalAssetCount > 0 ? min(1, (Double(batch.processedAssetCount) + batch.currentProgress.values.compactMap(\.fractionCompleted).reduce(0, +)) / Double(batch.totalAssetCount)) : 1
            content.secondaryText = L("完成 %d · 跳过 %d · 失败 %d · 取消 %d", batch.completedAssetCount, batch.skippedAssetCount, batch.failedAssetCount, batch.cancelledAssetCount)
                + " · \(Int(progress * 100))%"
            cell.accessibilityIdentifier = "libraryConversion.batch.\(batch.id.uuidString)"; cell.selectionStyle = .none
        case .pause: content.text = L("暂停"); content.textProperties.color = .systemBlue
        case .resume: content.text = L("继续"); content.textProperties.color = .systemBlue
        case .cancel: content.text = L("取消"); content.textProperties.color = .systemRed
        case .retry: content.text = L("重试失败项"); content.textProperties.color = .systemBlue
        }
        cell.contentConfiguration = content
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .preflight: perform { await $0.runPreflight() }
        case .start:
            guard !model.isStarting, (model.preflight?.eligibleAssetCount ?? 0) > 0 else { return }
            let alert = UIAlertController(title: L("开始转换？"),
                message: L("每个成功转换的物理文件会替换资料库中的旧文件；失败或取消的项目继续使用原文件。正在播放的旧文件会在播放释放后再清理。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("开始转换"), style: .default) { [weak self] _ in self?.perform { await $0.startConversion() } })
            present(alert, animated: true)
        case .pause(let id): perform { await $0.pause(id) }
        case .resume(let id): perform { await $0.resume(id) }
        case .cancel(let id): perform { await $0.cancel(id) }
        case .retry(let id): perform { await $0.retryFailures(id) }
        default: break
        }
    }
    private func perform(_ operation: @escaping @MainActor (LibraryAudioConversionViewModel) async -> Void) {
        guard operationTask == nil else { return }
        let model = model
        operationTask = Task { [weak self] in
            await operation(model)
            self?.operationTask = nil
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func targetName(_ target: AudioConversionTarget) -> String {
        switch target { case .alac: L("ALAC（无损）"); case .aacLC(let rate): "AAC-LC \(rate.kilobitsPerSecond) kbps" }
    }
    private func stateName(_ state: LibraryConversionBatchState) -> String {
        switch state {
        case .queued: L("等待中")
        case .running: L("转换中")
        case .paused: L("已暂停")
        case .cancelling: L("正在取消")
        case .completed: L("已完成")
        case .cancelled: L("已取消")
        }
    }
}
