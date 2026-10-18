import AppServices
import DesignSystem
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import Observation
import PlaybackAPI
import SafariServices
import SettingsAPI
import UIKit

/// The settings list owns native cells and navigation. Model notifications update
/// existing controls in place; they never replace the form or its scroll view.
@MainActor
open class SettingsViewController: UITableViewController, UIColorPickerViewControllerDelegate {
    public struct Addition {
        let title: String
        let systemImage: String
        let identifier: String
        let makeController: @MainActor () -> UIViewController

        public init(title: String, systemImage: String, identifier: String,
                    makeController: @escaping @MainActor () -> UIViewController) {
            self.title = title
            self.systemImage = systemImage
            self.identifier = identifier
            self.makeController = makeController
        }
    }

    enum Page {
        case root, category(SettingsDestination), icons, accentColor, transitions, conversion, maintenance, storageStatus
        case sleepTimer, metadata, availability, releaseInfo, diagnostics
        case providerPrivacy(PrivacyProviderDescriptor), sourcePrivacy(OnlineSourceConfiguration), license(SettingsDependencyLicense)
    }
    struct Section {
        let id: String
        let title: String
        var footer: String = ""
        var rows: [SettingsNativeRow]
    }
    let model: SettingsSceneModel
    var viewModel: SettingsViewModel { model.viewModel }
    var page: Page
    private let appearance: () -> MusicFreeAppearance
    private let setAppearance: (MusicFreeAppearance) -> Void
    private let language: () -> MusicFreeLanguage
    private let setLanguage: (MusicFreeLanguage) -> Void
    let setAccentColor: (UIColor) -> Void
    let releaseInfoProvider: any SettingsReleaseInfoProviding
    let diagnosticsProvider: any SettingsDiagnosticsProviding
    private let appIconOptions: [SettingsAppIconOption]
    private let appIconModel: AppIconSettingsViewModel
    private let appIconProvider: any SettingsAppIconProviding
    let sleepTimerServing: (any SleepTimerServing)?
    private let libraryConversion: (any LibraryConversionServing)?
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool
    private let additions: [Addition]
    private let pluginPages: PluginSettingsPageHost?
    private let onNavigationChange: ((SettingsDestination?) -> Void)?
    var sections: [Section] = []
    var rows: [String: SettingsNativeRow] = [:]
    private var dataSource: UITableViewDiffableDataSource<String, String>!
    private var loadTask: Task<Void, Never>?
    private var observationGeneration = 0
    let detailState = SettingsDetailState()
    var detailTasks: [Task<Void, Never>] = []
    var oneTimeDurationMinutes = 20
    var timerSnapshot = SleepTimerSnapshot.inactive
    var releaseInfo: SettingsReleaseInfo?
    var diagnosticsSnapshot = SettingsDiagnosticsSnapshot()
    var detailLoading = true
    var hasCheckedPrivacy = false
    var preparingLogShare = false
    var isPlaybackRateExpanded = false
    var pendingAccentColor: UIColor?
    var preferredCrossfade = false
    var rememberedCrossfadeDuration: Duration = .seconds(1)

    public init(
        model: SettingsSceneModel,
        layout: SettingsSceneLayout = .compact,
        appearance: @escaping () -> MusicFreeAppearance = { .system },
        setAppearance: @escaping (MusicFreeAppearance) -> Void = { _ in },
        language: @escaping () -> MusicFreeLanguage = { .english },
        setLanguage: @escaping (MusicFreeLanguage) -> Void = { _ in },
        setAccentColor: @escaping (UIColor) -> Void = { _ in },
        releaseInfoProvider: any SettingsReleaseInfoProviding = EmptySettingsReleaseInfoProvider(),
        diagnosticsProvider: any SettingsDiagnosticsProviding = EmptySettingsDiagnosticsProvider(),
        appIconOptions: [SettingsAppIconOption] = [],
        appIconProvider: any SettingsAppIconProviding = EmptySettingsAppIconProvider(),
        sleepTimerServing: (any SleepTimerServing)? = nil,
        libraryConversion: (any LibraryConversionServing)? = nil,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true,
        additions: [Addition] = [],
        pluginPages: PluginSettingsPageHost? = nil,
        onNavigationChange: ((SettingsDestination?) -> Void)? = nil
    ) {
        self.model = model
        switch layout {
        case .compact: page = .root
        case .detail(let destination): page = .category(destination)
        }
        self.appearance = appearance
        self.setAppearance = setAppearance
        self.language = language
        self.setLanguage = setLanguage
        self.setAccentColor = setAccentColor
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.appIconOptions = appIconOptions
        self.appIconProvider = appIconProvider
        appIconModel = AppIconSettingsViewModel(provider: appIconProvider)
        self.sleepTimerServing = sleepTimerServing
        self.libraryConversion = libraryConversion
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
        self.additions = additions
        self.pluginPages = pluginPages
        self.onNavigationChange = onNavigationChange
        super.init(style: .insetGrouped)
        extendedLayoutIncludesOpaqueBars = true
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { loadTask?.cancel(); detailTasks.forEach { $0.cancel() } }

    open override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(SettingsNativeCell.self, forCellReuseIdentifier: "setting")
        dataSource = SettingsNativeDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: "setting", for: indexPath) as! SettingsNativeCell
            if let row = self?.rows[id] { cell.configure(row) }
            cell.showsReorderControl = self?.canReorderMetadata(at: indexPath) ?? false
            return cell
        }
        (dataSource as? SettingsNativeDataSource)?.sectionText = { [weak self] index, footer in
            guard let self, self.sections.indices.contains(index) else { return nil }
            let section = self.sections[index]
            let text = footer ? section.footer : section.title
            return text.isEmpty ? nil : text
        }
        (dataSource as? SettingsNativeDataSource)?.canMoveRow = { [weak self] in self?.canReorderMetadata(at: $0) ?? false }
        (dataSource as? SettingsNativeDataSource)?.moveRow = { [weak self] in self?.reorderMetadata(from: $0, to: $1) }
        if case .metadata = page {
            // Provider reordering keeps this table in editing mode; action rows
            // must still receive taps while the reorder handles are visible.
            tableView.allowsSelectionDuringEditing = true
            tableView.setEditing(true, animated: false)
        }
        pluginPages?.start()
        render()
        let model = model
        loadTask = Task { await model.loadIfNeeded() }
        startDetailTasks()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appIconModel.refreshSelection()
        reloadLocalizedContent()
        if case .storageStatus = page {
            let viewModel = viewModel
            detailTasks.append(Task { _ = await viewModel.refreshStorageUsage() })
        }
        onNavigationChange?(destination)
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkEntryPrivacy()
    }

    open override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? { tableView }

    public func reloadLocalizedContent() {
        guard isViewLoaded else { return }
        view.tintColor = MusicFreeUIColorTokens.accent
        render()
        for controller in navigationController?.viewControllers ?? [] where controller !== self {
            (controller as? SettingsViewController)?.refreshVisibleContent()
        }
    }

    func refreshVisibleContent() { if isViewLoaded { render() } }

    public func updateNavigationDestination(_ destination: SettingsDestination?) {
        switch page {
        case .root:
            guard let navigationController else { return }
            if let destination {
                if let current = navigationController.topViewController as? SettingsViewController,
                   current !== self, current.destination == destination { return }
                let detail = child(.category(destination))
                navigationController.setViewControllers([self, detail], animated: false)
            } else if navigationController.topViewController !== self {
                navigationController.popToViewController(self, animated: false)
            }
        default:
            let next = destination ?? .general
            guard self.destination != next else { return }
            navigationController?.popToViewController(self, animated: false)
            page = .category(next)
            if isViewLoaded {
                render()
                tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
            }
        }
    }

    var destination: SettingsDestination? {
        switch page {
        case .root: nil
        case .category(let destination): destination
        case .icons, .accentColor: .general
        case .conversion: .importing
        case .maintenance, .storageStatus: .storage
        case .sleepTimer, .transitions: .playback
        case .metadata, .availability: .importing
        case .releaseInfo, .diagnostics, .license: .about
        case .providerPrivacy, .sourcePrivacy: .privacy
        }
    }

    func child(_ page: Page) -> SettingsViewController {
        let controller = SettingsViewController(
            model: model, appearance: appearance, setAppearance: setAppearance,
            language: language, setLanguage: setLanguage, setAccentColor: setAccentColor,
            releaseInfoProvider: releaseInfoProvider, diagnosticsProvider: diagnosticsProvider,
            appIconOptions: appIconOptions, appIconProvider: appIconProvider,
            sleepTimerServing: sleepTimerServing, libraryConversion: libraryConversion,
            metadataServerEnabled: metadataServerEnabled, lyricsEnabled: lyricsEnabled,
            additions: additions, pluginPages: pluginPages, onNavigationChange: onNavigationChange
        )
        controller.page = page
        return controller
    }

    func push(_ controller: UIViewController, destination: SettingsDestination) {
        onNavigationChange?(destination)
        navigationController?.pushViewController(controller, animated: true)
    }

    func render() {
        observationGeneration += 1
        let generation = observationGeneration
        let next = withObservationTracking { makeSections() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.render()
            }
        }
        sections = next
        rows = Dictionary(uniqueKeysWithValues: next.flatMap(\.rows).map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in next {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
        }
        let current = dataSource.snapshot()
        if current.sectionIdentifiers != snapshot.sectionIdentifiers || current.itemIdentifiers != snapshot.itemIdentifiers {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // No reload/reconfigure for value updates: preserve switches, active slider
        // gestures, focus and contentOffset even when an external snapshot arrives.
        for cell in tableView.visibleCells {
            guard let cell = cell as? SettingsNativeCell,
                  let id = cell.rowID, let row = rows[id] else { continue }
            cell.configure(row)
            if let path = dataSource.indexPath(for: id) { cell.showsReorderControl = canReorderMetadata(at: path) }
        }
        for (index, section) in next.enumerated() {
            tableView.headerView(forSection: index)?.textLabel?.text = section.title
            tableView.footerView(forSection: index)?.textLabel?.text = section.footer
        }
    }

    func makeSections() -> [Section] {
        switch page {
        case .root: title = L("设置"); tableView.accessibilityIdentifier = "settings.form"
        case .category(let category): title = category.title; tableView.accessibilityIdentifier = "settings.detail.\(category.rawValue)"
        case .icons: title = L("应用图标"); tableView.accessibilityIdentifier = "settings.icons.form"
        case .conversion: title = L("音频转换"); tableView.accessibilityIdentifier = "settings.import.audioConversion.form"
        case .storageStatus: title = L("存储状态"); tableView.accessibilityIdentifier = "settings.storage.status.form"
        case .maintenance: title = L("存储维护"); tableView.accessibilityIdentifier = "settings.storage.maintenance.form"
        default: configureDetailTitle()
        }
        switch viewModel.loadState {
        case .idle, .loading:
            return [.init(id: "loading", title: "", rows: [text("loading", L("加载设置"))])]
        case .failed(let failure):
            var recoveryRows = [
                text("failure", failure.message, detail: failure.diagnosticCode),
                action("retry", L("重试")) { [weak self] in
                    guard let self else { return }; Task { await self.viewModel.retry() }
                }, resetRow(id: "settings.recovery.reset")
            ]
#if DEBUG
            recoveryRows.append(action("settings.debug.resetAllPrivacy", L("重置全部隐私(DEBUG Only)"), destructive: true) { [weak self] in
                self?.viewModel.resetAllPrivacy()
            })
#endif
            return [.init(id: "failed", title: L("设置加载失败"), rows: recoveryRows)]
        case .loaded: break
        }
        var result: [Section] = []
        if let failure = viewModel.lastFailure {
            var rows = [text("failure", failure.message, detail: failure.diagnosticCode)]
            if viewModel.canRetryFailedSave {
                rows.append(action("retrySave", L("重试保存")) { [weak self] in self?.viewModel.retryFailedSave() })
            }
            result.append(.init(id: "failure", title: L("状态"), rows: rows))
        }
        switch page {
        case .root:
            result += [appearanceSection(), playbackSection(), importSection(), appSupportSection()]
            if !additions.isEmpty { result.append(additionsSection()) }
            result.append(.init(id: "reset", title: "", rows: [resetRow()]))
        case .category(let category):
            switch category {
            case .general:
                result.append(appearanceSection())
                if let section = pluginManagementSection() { result.append(section) }
                if !additions.isEmpty { result.append(additionsSection()) }
            case .playback: result.append(playbackSection())
            case .importing: result.append(importSection())
            case .storage: result += [storageEntrySection(), .init(id: "reset", title: "", rows: [resetRow()])]
            case .privacy: result += privacySections()
            case .about: result.append(aboutSection())
            }
        case .icons:
            let changing = appIconModel.changingAlternateIconName != nil || appIconModel.isChangingToPrimaryIcon
            let iconRows = appIconOptions.map { option in
                var row = action("settings.icon.\(option.id)", L(option.title),
                    detail: "") { [weak self] in
                    guard let self else { return }; Task { await self.appIconModel.select(option) }
                }
                row.image = UIImage(named: option.previewAssetName)
                row.isSelected = appIconModel.isSelected(option)
                row.trailingValue = row.isSelected ? L("已选择") : ""
                row.enabled = appIconModel.supportsAlternateIcons && !changing
                return row
            }
            result.append(.init(id: "icons", title: "", rows: iconRows))
            if let failure = appIconModel.failureMessage { result.append(.init(id: "iconFailure", title: L("状态"), rows: [text("iconFailure", failure)])) }
        case .conversion: result += conversionSections()
        case .storageStatus: result.append(storageSection())
        case .maintenance: result += maintenanceSections()
        default: result += detailSections()
        }
        return result
    }

    func appearanceSection() -> Section {
        var rows: [SettingsNativeRow] = []
        if !appIconOptions.isEmpty {
            let selected = appIconOptions.first { appIconModel.isSelected($0) }
            var icon = action("settings.appIcon", L("应用图标"), disclosure: true) { [weak self] in
                guard let self else { return }; self.push(self.child(.icons), destination: .general)
            }
            icon.image = selected.flatMap { UIImage(named: $0.previewAssetName) } ?? UIImage(systemName: "app")
            icon.trailingValue = selected.map { L($0.title) } ?? ""
            rows.append(icon)
        }
        rows.append(menu("settings.language", L("应用语言"), value: language().title, symbol: "globe",
            options: MusicFreeLanguage.allCases.map { option in
                UIAction(title: option.title, state: option == language() ? .on : .off) { [weak self] _ in
                    self?.setLanguage(option); self?.reloadLocalizedContent()
                }
            }))
        rows.append(menu("settings.appearance", L("配色"), value: appearance().title, symbol: "circle.lefthalf.filled",
            options: MusicFreeAppearance.allCases.map { option in
                UIAction(title: option.title, image: UIImage(systemName: option.systemImage), state: option == appearance() ? .on : .off) { [weak self] _ in
                    self?.setAppearance(option); self?.reloadLocalizedContent()
                }
            }))
        var accent = action("settings.accentColor", L("强调色"), symbol: "paintpalette", disclosure: true) { [weak self] in
            guard let self else { return }; self.push(self.child(.accentColor), destination: .general)
        }
        accent.trailingValue = accentColorTitle
        accent.swatchColor = MusicFreeAccentColorStore.uiColor(forHex: MusicFreeAccentColorStore.hexValue)
        rows.append(accent)
        return .init(id: "appearance", title: L("外观"), rows: rows)
    }

    public func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        pendingAccentColor = viewController.selectedColor
    }

    public func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        let color = pendingAccentColor ?? viewController.selectedColor
        pendingAccentColor = nil
        UserDefaults.standard.set(MusicFreeAccentColorStore.hexString(for: color), forKey: "musicfree.customAccentColor")
        setAccentColor(color)
        reloadLocalizedContent()
    }

    func playbackSection() -> Section {
        let preferences = viewModel.settings.playbackPreferences
        var rate = action("settings.playback.rate.expand", L("默认播放速度"), symbol: "speedometer") { [weak self] in
            guard let self else { return }; self.isPlaybackRateExpanded.toggle(); self.render()
        }
        rate.trailingValue = String(format: "%.2gx", viewModel.displayedPlaybackRate)
        rate.accessorySymbol = isPlaybackRateExpanded ? "chevron.up" : "chevron.down"
        var rows = [rate]
        if isPlaybackRateExpanded {
            rows.append(slider("settings.playback.rate", L("默认播放速度"), value: viewModel.displayedPlaybackRate,
                range: PlaybackRate.minimumValue...PlaybackRate.maximumValue, step: 0.25,
                valueText: String(format: "%.2gx", viewModel.displayedPlaybackRate), enabled: viewModel.supportsVariableRate,
                format: { String(format: "%.2gx", $0) }) { [weak self] in self?.viewModel.setPlaybackRate($0) })
        }
        rows += [
            action("settings.playback.sleepTimer.entry", L("Sleep timer"), symbol: "moon.zzz", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.sleepTimer), destination: .playback)
            }]
        rows += pluginRows(category: .playback, destination: .playback)
        if viewModel.supportsFade || viewModel.supportsGapless || viewModel.supportsCrossfade {
            rows.append(action("settings.playback.transitions.entry", L("歌曲过渡"), detail: transitionSummary, symbol: "waveform.path", disclosure: true) { [weak self] in
                guard let self else { return }; self.push(self.child(.transitions), destination: .playback)
            })
        }
        if !viewModel.supportsEqualizer {
            rows.append(text("equalizerNote", L("当前播放引擎未启用均衡器，保存的均衡器设置会在支持后生效。")))
        }
        return .init(id: "playback", title: L("播放偏好"), rows: rows)
    }

    func importSection() -> Section {
        let preferences = viewModel.settings.importPreferences
        let providers = preferences.runtimeMetadataProviders.filter { $0.isEnabled && (metadataServerEnabled || $0.provider != .metadataServer) }
        let available = viewModel.metadataEnrichmentSnapshot.providerStatuses.filter {
            providers.map(\.provider).contains($0.provider) && $0.isRegistered && $0.authorization == .authorized
        }.count
        let metadataStatus = providers.isEmpty ? L("未开启") : (available == 0 ? L("暂无可用来源") : L("%d 个来源可用", available))
        let onlineCount = viewModel.onlineSourceConfigurations.filter { $0.isEnabled && isOnlineSourcePrivacyAccepted($0) }.count
        let onlineStatus = !viewModel.isPrivacyPolicyAccepted ? L("需要先同意隐私政策") : (!viewModel.isOnlineSourcesEnabled ? L("未开启") : (onlineCount == 0 ? L("暂无可用来源") : L("%d 个来源可用", onlineCount)))
        return .init(id: "import", title: L("导入与资料库"), footer: L("跳过已有内容，或在导入结果中报告重复文件。替换和保留两份的历史设置会保留，但当前导入器暂不支持。"), rows: [
            menu("settings.import.duplicatePolicy", L("重复内容"), value: duplicatePolicyTitle(preferences.duplicatePolicy), symbol: "doc.on.doc",
                options: [DuplicateImportPolicy.skipExisting, .reportExisting].map { policy in
                    UIAction(title: duplicatePolicyTitle(policy), state: preferences.duplicatePolicy == policy ? .on : .off) { [weak self] _ in
                        self?.viewModel.setDuplicateImportPolicy(policy)
                    }
                }),
            action("settings.import.audioConversion.entry", L("音频转换"), detail: preferences.audioConversion.automaticallyConvertLosslessImports ? conversionTitle(preferences.audioConversion.target) : L("未开启"), symbol: "waveform.badge.plus", disclosure: true) { [weak self] in
                guard let self else { return }; self.push(self.child(.conversion), destination: .importing)
            },
            action("settings.import.metadataEnrichment.entry", L("元数据填充"), detail: metadataStatus, symbol: "wand.and.stars", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.metadata), destination: .importing)
            },
            action("settings.import.onlineSourceAvailability.entry", L("在线源可用性"), detail: onlineStatus, symbol: "externaldrive.connected.to.line.below", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.availability), destination: .importing)
            }
        ])
    }

    func duplicatePolicyTitle(_ policy: DuplicateImportPolicy) -> String {
        switch policy {
        case .skipExisting: L("跳过已有内容")
        case .reportExisting: L("报告重复内容")
        case .replaceExisting: L("替换已有内容（暂不支持）")
        case .keepBoth: L("保留两份（暂不支持）")
        }
    }

    func conversionSections() -> [Section] {
        let preferences = viewModel.settings.importPreferences.audioConversion
        var sections = [Section(id: "conversion", title: L("导入转换"), footer: L("前台按设置并发转码；后台仅在音乐播放中运行一个转码任务，暂停、停止或缓冲时会暂停并保留进度，继续播放后自动恢复。"), rows: [
            toggle("settings.import.audioConversion.enabled", L("启用导入转换"), value: preferences.automaticallyConvertLosslessImports) { [weak self] in self?.viewModel.setAutomaticAudioConversionEnabled($0) },
            menu("settings.import.audioConversion.target", L("转换格式"), value: conversionTitle(preferences.target),
                options: ([AudioConversionTarget.alac] + AACLCBitRate.allCases.map { .aacLC($0) }).map { target in
                    UIAction(title: conversionTitle(target), state: target == preferences.target ? .on : .off) { [weak self] _ in self?.viewModel.setAudioConversionTarget(target) }
                }),
            menu("settings.import.audioConversion.concurrency", L("同时转换"), value: "\(preferences.maximumConcurrency.rawValue)", options: MediaConversionConcurrency.allCases.map { value in
                UIAction(title: "\(value.rawValue)", state: value == preferences.maximumConcurrency ? .on : .off) { [weak self] _ in self?.viewModel.setAudioConversionConcurrency(value) }
            })
        ])]
        if let libraryConversion {
            sections.append(.init(id: "libraryConversion", title: L("现有资料库"), rows: [
                action("settings.import.audioConversion.library", L("转换已有资料库"), symbol: "waveform", disclosure: true) { [weak self] in
                    guard let self else { return }
                    self.push(LibraryAudioConversionViewController(service: libraryConversion, scope: .allLocalMedia, initialTarget: self.viewModel.settings.importPreferences.audioConversion.target), destination: .importing)
                }
            ]))
        }
        return sections
    }

    func storageEntrySection() -> Section {
        .init(id: "storage", title: L("存储"), rows: [
            action("settings.storage.status", L("存储状态"), symbol: "internaldrive", disclosure: true) { [weak self] in
                guard let self else { return }; self.push(self.child(.storageStatus), destination: .storage)
            }
        ])
    }

    func storageSection() -> Section {
        var rows: [SettingsNativeRow] = []
        if let usage = viewModel.storageUsage {
            rows += [text("storage.media", L("媒体文件"), detail: bytes(usage.managedMediaBytes)),
                     text("storage.cache", L("导入暂存"), detail: bytes(usage.cacheBytes)),
                     text("storage.quarantine", L("隔离文件"), detail: bytes(usage.quarantineBytes))]
            if let available = usage.availableBytes { rows.append(text("storage.available", L("可用空间"), detail: bytes(available))) }
            if usage.pendingRemovalCount > 0 { rows.append(text("storage.pending", L("有 %d 个待完成的删除事务", usage.pendingRemovalCount))) }
        } else { rows.append(text("storage.unavailable", L("存储状态暂不可用"))) }
        rows.append(action("settings.storage.maintenance", L("存储维护"), detail: L("清理暂存、修复删除事务或清理已完成的隔离文件。"), symbol: "wrench.and.screwdriver", disclosure: true) { [weak self] in
            guard let self else { return }; self.push(self.child(.maintenance), destination: .storage)
        })
        return .init(id: "storage", title: L("存储状态"), rows: rows)
    }

    func maintenanceSections() -> [Section] {
        let maximum = viewModel.maximumCacheLimitBytes ?? viewModel.displayedCacheLimitBytes
        let days = Int(viewModel.settings.storagePreferences.stagingRetention.components.seconds / 86400)
        var result = [Section(id: "storagePolicy", title: L("存储策略"), rows: [
            toggle("settings.storage.autoPrune", L("自动整理缓存"), value: viewModel.settings.storagePreferences.automaticallyPruneCache) { [weak self] in self?.viewModel.setAutomaticallyPruneCache($0) },
            slider("settings.storage.cacheLimit", L("缓存上限"), value: CacheLimitSliderScale.position(for: viewModel.displayedCacheLimitBytes, maximumBytes: maximum), range: 0...1, step: 0,
                valueText: CacheLimitSliderScale.text(for: viewModel.displayedCacheLimitBytes), enabled: viewModel.maximumCacheLimitBytes != nil,
                format: { CacheLimitSliderScale.text(for: CacheLimitSliderScale.bytes(for: $0, maximumBytes: maximum)) }) { [weak self] in
                    self?.viewModel.setCacheLimit(bytes: CacheLimitSliderScale.bytes(for: $0, maximumBytes: maximum))
                },
            menu("settings.storage.stagingRetention", L("暂存保留时间"), value: L("%d days", days), options: (0...30).map { value in
                UIAction(title: L("%d days", value), state: value == days ? .on : .off) { [weak self] _ in self?.viewModel.setStagingRetention(.seconds(value * 86400)) }
            })
        ]), Section(id: "maintenanceNote", title: L("操作前请确认"), rows: [
            text("maintenanceNote", L("这些操作只处理应用生成的暂存、隔离文件和已记录的维护事务。"), detail: L("不会删除已经进入资料库的媒体文件。清理已完成的文件后，不能从隔离目录恢复这些副本。"))
        ])]
        switch viewModel.maintenanceState {
        case .idle: break
        case .loading: result.append(.init(id: "maintenanceStatus", title: L("最近一次操作"), rows: [text("maintenanceStatus", L("正在维护存储"))]))
        case .failed(let message): result.append(.init(id: "maintenanceStatus", title: L("最近一次操作"), rows: [text("maintenanceStatus", message)]))
        case .completed(let value): result.append(.init(id: "maintenanceStatus", title: L("最近一次操作"), rows: [text("maintenanceStatus", L("维护完成"), detail: "\(L("已释放 %@", bytes(value.freedBytes))) · \(L("已修复 %d 个待删除事务", value.repairedPendingRemovalCount))")]))
        }
        for maintenance in StorageMaintenanceAction.allCases {
            var row = action(maintenance.accessibilityIdentifier, maintenance.title, detail: "\(maintenance.detail)\n\(maintenance.expectation)", symbol: maintenance.systemImage, destructive: maintenance != .repairPendingRemovals) { [weak self] in
                self?.confirmMaintenance(maintenance)
            }
            row.enabled = !viewModel.isRefreshingStorage && !viewModel.isMaintainingStorage
            result.append(.init(id: "maintenance.\(maintenance)", title: maintenance.title, rows: [row]))
        }
        return result
    }

    func privacySections() -> [Section] {
        var application = [text("privacy.status", viewModel.isPrivacyPolicyAccepted ? L("应用隐私政策已同意") : L("未同意应用隐私政策时，元数据、歌词和在线源都不会发起网络请求。"))]
        if viewModel.isPrivacyPolicyAccepted {
            application.append(action("settings.privacy.application.revoke", L("撤回同意并关闭联网服务"), destructive: true) { [weak self] in
                self?.confirm(title: L("撤回应用隐私政策？"), message: L("这会撤销应用级同意，同时撤销并停用所有在线源；来源配置和已经导入本地的媒体会保留。"), button: L("撤回并关闭所有在线源")) { [weak self] in self?.viewModel.revokeOnlinePrivacy() }
            })
        } else {
            application.append(action("settings.privacy.application.accept", L("同意应用隐私政策")) { [weak self] in self?.viewModel.acceptPrivacyPolicy() })
        }
        application.append(action("privacy.policy", L("查看完整隐私政策"), symbol: "safari") { [weak self] in self?.present(SFSafariViewController(url: PrivacyPolicyURLs.app), animated: true) })
        var sources = viewModel.onlineSourceConfigurations.map { configuration in
            action("settings.privacy.onlineSource.\(configuration.sourceID.rawValue).privacy", configuration.displayName, detail: isOnlineSourcePrivacyAccepted(configuration) ? L("已同意") : L("待同意"), symbol: onlineSourceProviderSymbol(configuration.providerKind), disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.sourcePrivacy(configuration)), destination: .privacy)
            }
        }
        if sources.isEmpty { sources = [text("privacy.noSources", L("添加来源后，这里会显示每个来源独立的隐私协议状态。"))] }
        var ids = viewModel.metadataEnrichmentSnapshot.providerStatuses.filter {
            isProviderVisible($0.provider.rawValue, kind: .metadata)
        }.map { $0.provider.rawValue }
        if lyricsEnabled {
            ids += visibleLyricsProviders.map { $0.provider.rawValue }
        }
        var seen = Set<String>()
        let providers = ids.filter { seen.insert($0).inserted }.map { id in
            let descriptor = PrivacyProviderCatalog.descriptor(for: id)
            return action("settings.privacy.provider.\(id)", descriptor.title, detail: viewModel.settings.importPreferences.privacyPreferences.isProviderPolicyAccepted(id) ? L("已确认") : L("未确认"), symbol: "network", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.providerPrivacy(descriptor)), destination: .privacy)
            }
        }
        return [.init(id: "applicationPrivacy", title: L("应用隐私政策"), footer: L("首次进入在线源时会单独弹出应用级协议；这里用于查看和撤回同意。撤回后会同时停用所有在线源。"), rows: application),
                .init(id: "sourcePrivacy", title: L("在线源隐私协议"), footer: L("每个来源单独保存同意状态。点击来源查看协议详情并撤销；撤销某个来源会立即停用它，撤销应用隐私协议会同时清除所有来源同意。"), rows: sources),
                .init(id: "providerPrivacy", title: L("Provider 服务说明"), footer: L("Provider 同意独立保存；撤回后会同时关闭对应 Provider，未启用的 Provider 不会发起请求。"), rows: providers)]
    }

    var visibleMetadataProviders: [MetadataProviderPreference] {
        viewModel.settings.importPreferences.metadataProviders.filter {
            isProviderVisible($0.provider.rawValue, kind: .metadata)
        }
    }

    var visibleLyricsProviders: [LyricsProviderPreference] {
        viewModel.settings.importPreferences.lyricsProviders.filter {
            isProviderVisible($0.provider.rawValue, kind: .lyrics)
        }
    }

    private func isProviderVisible(_ providerID: String, kind: PluginKind) -> Bool {
        if providerID == MetadataProviderID.metadataServer.rawValue && !metadataServerEnabled { return false }
        let registered: Bool
        switch kind {
        case .metadata:
            registered = viewModel.metadataEnrichmentSnapshot.status(for: .init(rawValue: providerID))?.isRegistered == true
        case .lyrics:
            registered = lyricsEnabled && viewModel.availableLyricsProviderIDs.contains(.init(rawValue: providerID))
        default: return false
        }
        guard registered else { return false }
        guard let pluginPages else { return true }
        guard let snapshot = pluginPages.snapshots.first(where: {
            $0.descriptor.kinds.contains(kind)
                && ($0.descriptor.dataProviderID ?? $0.id.rawValue) == providerID
        }), snapshot.state != .compiledOut else { return false }
        return snapshot.preference.isVisible
            || UserDefaults.standard.bool(forKey: PluginSettingsViewController.showHiddenStorageKey)
    }

    func appSupportSection() -> Section {
        var rows = pluginManagementSection()?.rows ?? []
        rows.append(action("settings.privacy", L("隐私与联网服务"), symbol: "hand.raised.circle", disclosure: true) { [weak self] in
            guard let self else { return }
            self.push(self.child(.category(.privacy)), destination: .privacy)
        })
        rows += storageEntrySection().rows
        rows += aboutSection().rows
        return .init(id: "appSupport", title: L("应用与支持"), rows: rows)
    }

    func aboutSection() -> Section {
        .init(id: "about", title: L("关于"), rows: [
            action("settings.about", L("版本与第三方许可"), symbol: "info.circle", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.releaseInfo), destination: .about)
            },
            action("settings.diagnostics", L("诊断信息"), symbol: "stethoscope", disclosure: true) { [weak self] in
                guard let self else { return }
                self.push(self.child(.diagnostics), destination: .about)
            }
        ])
    }

    func pluginRows(category: PluginSettingsPageHost.Category, destination: SettingsDestination) -> [SettingsNativeRow] {
        guard let pluginPages else { return [] }
        let registeredRows = pluginPages.categoryEntries(category: category).map { entry in
            let snapshot = pluginPages.snapshots.first { $0.id == entry.pluginID }
            return action(entry.navigationIdentifier, L(entry.title),
                detail: snapshot?.preference.isEnabled == true ? L("已开启") : L("已关闭"),
                symbol: entry.systemImage, disclosure: true) { [weak self] in
                    guard let self, let page = pluginPages.makePage(entryID: entry.id) else { return }
                    self.push(page, destination: destination)
                }
        }
        let discoveredRows = pluginPages.categoryPlugins(category: category).map { snapshot in
            action("settings.plugins.\(snapshot.id.rawValue).entry", L(snapshot.descriptor.name),
                detail: L("已开启"), symbol: snapshot.descriptor.kinds.contains(.dsp) ? "slider.horizontal.3" : "puzzlepiece.extension",
                disclosure: true) { [weak self] in
                    guard let self, let page = pluginPages.makeSettingsPage(pluginID: snapshot.id) else { return }
                    self.push(page, destination: destination)
                }
        }
        return registeredRows + discoveredRows
    }

    func pluginManagementSection() -> Section? {
        guard let pluginPages else { return nil }
        return .init(id: "plugins", title: "", rows: [
            action("settings.plugins.entry", L("插件"), symbol: "puzzlepiece.extension", disclosure: true) { [weak self] in
                self?.push(pluginPages.makeOverviewPage(), destination: .general)
            }
        ])
    }

    func additionsSection() -> Section {
        .init(id: "additions", title: "", rows: additions.map { addition in
            action(addition.identifier, L(addition.title), symbol: addition.systemImage, disclosure: true) { [weak self] in
                self?.push(addition.makeController(), destination: .general)
            }
        })
    }

    func resetRow(id: String = "settings.reset") -> SettingsNativeRow {
        var row = action(id, L("恢复默认设置"), symbol: "arrow.counterclockwise", destructive: true) { [weak self] in
            self?.confirm(title: L("恢复默认设置？"), message: L("播放、导入和存储偏好将恢复为默认值。"), button: L("恢复默认设置")) { [weak self] in
                guard let self else { return }; Task { await self.viewModel.confirmReset() }
            }
        }
        row.enabled = !viewModel.isSaving
        return row
    }

    func confirmMaintenance(_ action: StorageMaintenanceAction) {
        confirm(title: action.title, message: action.detail, button: L("继续")) { [weak self] in
            guard let self else { return }
            self.viewModel.requestStorageMaintenance(action)
            Task { await self.viewModel.confirmStorageMaintenance() }
        }
    }

    func confirm(title: String, message: String, button: String, identifier: String? = nil, perform: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let confirmation = UIAlertAction(title: button, style: .destructive) { _ in perform() }
        confirmation.accessibilityIdentifier = identifier
        alert.addAction(confirmation)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        present(alert, animated: true)
    }

    open override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id], row.enabled else { return }
        row.action?()
    }

    func conversionTitle(_ target: AudioConversionTarget) -> String {
        switch target {
        case .alac: L("ALAC（无损）")
        case .aacLC(let bitRate): "AAC-LC \(bitRate.kilobitsPerSecond) kbps"
        }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    func text(_ id: String, _ title: String, detail: String = "") -> SettingsNativeRow { .init(id: id, title: title, detail: detail) }
    func action(_ id: String, _ title: String, detail: String = "", symbol: String? = nil, disclosure: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, detail: detail, image: symbol.flatMap { UIImage(systemName: $0) }, disclosure: disclosure, destructive: destructive, action: action)
    }
    func toggle(_ id: String, _ title: String, value: Bool, change: @escaping (Bool) -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, enabled: viewModel.canEditPlayback, control: .toggle(value, change))
    }
    func menu(_ id: String, _ title: String, value: String, symbol: String? = nil, options: [UIAction]) -> SettingsNativeRow {
        .init(id: id, title: title, image: symbol.flatMap { UIImage(systemName: $0) }, enabled: viewModel.canEditPlayback, control: .menu(value, UIMenu(children: options)))
    }
    func slider(_ id: String, _ title: String, value: Double, range: ClosedRange<Double>, step: Double, valueText: String, enabled: Bool = true, format: @escaping (Double) -> String = { String(format: "%.2f", $0) }, save: @escaping (Double) -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, detail: valueText, enabled: enabled && viewModel.canEditPlayback, control: .slider(value, range, step, format, save))
    }
    func durationRow(_ id: String, _ title: String, _ duration: Duration, save: @escaping (Duration) -> Void) -> SettingsNativeRow {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return slider("settings.playback.\(id)", title, value: seconds, range: 0...3, step: 0.1, valueText: String(format: "%.1f s", seconds), format: { String(format: "%.1f s", $0) }) { save(.seconds($0)) }
    }
}
