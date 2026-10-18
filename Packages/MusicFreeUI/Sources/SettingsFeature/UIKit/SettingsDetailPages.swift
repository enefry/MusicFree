import AppServices
import BuildInfo
import DesignSystem
import Foundation
import LibraryAPI
import MediaSourceAPI
import Observation
import MusicDomain
import PlaybackAPI
import SafariServices
import SettingsAPI
import UIKit
import WebKit

@MainActor
@Observable
final class SettingsDetailState {
    enum Intent { case idle, starting, cancelling }
    var metadata = MetadataEnrichmentSnapshot()
    var lyrics = LyricsPreloadSnapshot()
    var scanIntent = Intent.idle
    var lyricsIntent = Intent.idle

    func apply(_ value: MetadataEnrichmentSnapshot) {
        if scanIntent == .starting && value.scan.status == .idle { return }
        if scanIntent == .cancelling && value.scan.status == .scanning { return }
        metadata = value
        if value.scan.status != .scanning { scanIntent = .idle }
    }
    func apply(_ value: LyricsPreloadSnapshot) {
        if lyricsIntent == .starting && value.status == .idle { return }
        if lyricsIntent == .cancelling && value.status == .downloading { return }
        lyrics = value
        if value.status != .downloading { lyricsIntent = .idle }
    }
}

@MainActor
extension SettingsViewController {
    func configureDetailTitle() {
        let identifier: String
        switch page {
        case .accentColor: title = L("强调色"); identifier = "settings.accentColor.form"
        case .transitions: title = L("歌曲过渡"); identifier = "settings.playback.transitions.form"
        case .sleepTimer: title = L("Sleep timer"); identifier = "settings.sleepTimer.form"
        case .metadata: title = L("元数据填充"); identifier = "settings.import.metadataEnrichment"
        case .availability: title = L("在线源可用性"); identifier = "settings.import.onlineSourceAvailability"
        case .releaseInfo: title = L("关于与许可"); identifier = "settings.about.form"
        case .diagnostics: title = L("诊断信息"); identifier = "settings.diagnostics.form"
        case .license(let dependency): title = dependency.name; identifier = "settings.license.\(dependency.id)"
        case .providerPrivacy(let descriptor): title = descriptor.title; identifier = "settings.privacy.provider.details.\(descriptor.id)"
        case .sourcePrivacy(let configuration): title = configuration.displayName; identifier = "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).details"
        default: return
        }
        tableView.accessibilityIdentifier = identifier
        navigationItem.largeTitleDisplayMode = .never
    }

    func detailSections() -> [Section] {
        switch page {
        case .accentColor: accentColorSections()
        case .transitions: transitionSections()
        case .sleepTimer: sleepTimerSections()
        case .metadata: metadataSections()
        case .availability: availabilitySections()
        case .providerPrivacy(let descriptor): providerPrivacySections(descriptor)
        case .sourcePrivacy(let configuration): sourcePrivacySections(configuration)
        case .releaseInfo: releaseSections()
        case .diagnostics: diagnosticSections()
        case .license(let dependency): licenseSections(dependency)
        default: []
        }
    }

    func startDetailTasks() {
        switch page {
        case .sleepTimer:
            if let serving = sleepTimerServing {
                timerSnapshot = serving.snapshot
                detailTasks.append(Task { [weak self] in
                    for await snapshot in serving.makeSnapshotStream() {
                        guard !Task.isCancelled else { return }
                        self?.timerSnapshot = snapshot
                        self?.render()
                    }
                })
                detailTasks.append(Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        self?.render()
                    }
                })
            }
        case .metadata:
            viewModel.resumeMetadataObservation()
            viewModel.resumeLyricsPreloadObservation()
            detailState.metadata = viewModel.metadataEnrichmentSnapshot
            detailState.lyrics = viewModel.lyricsPreloadSnapshot
            let viewModel = viewModel
            detailTasks.append(Task { [weak self] in
                for await snapshot in await viewModel.makeMetadataSnapshotStream() {
                    guard !Task.isCancelled else { return }
                    self?.detailState.apply(snapshot)
                }
            })
            detailTasks.append(Task { [weak self] in
                for await snapshot in await viewModel.makeLyricsPreloadSnapshotStream() {
                    guard !Task.isCancelled else { return }
                    self?.detailState.apply(snapshot)
                }
            })
        case .releaseInfo:
            let provider = releaseInfoProvider
            detailTasks.append(Task { [weak self] in
                let info = await provider.releaseInfo()
                guard !Task.isCancelled else { return }
                self?.releaseInfo = info; self?.detailLoading = false; self?.render()
            })
        case .diagnostics:
            let provider = diagnosticsProvider
            detailTasks.append(Task { [weak self] in
                let snapshot = await provider.diagnostics()
                guard !Task.isCancelled else { return }
                self?.diagnosticsSnapshot = snapshot; self?.detailLoading = false; self?.render()
            })
        default: break
        }
    }

    func checkEntryPrivacy() {
        switch page { case .metadata, .availability: break; default: return }
        guard !hasCheckedPrivacy else { return }
        hasCheckedPrivacy = true
        let model = model
        detailTasks.append(Task { [weak self] in
            await model.loadIfNeeded()
            await model.viewModel.waitForPendingWork()
            guard !Task.isCancelled, let self, !self.viewModel.isPrivacyPolicyAccepted else { return }
            self.presentPrivacy(.application, onAccept: { [weak self] in self?.viewModel.acceptPrivacyPolicy() }, onDecline: { [weak self] in
                self?.viewModel.revokeOnlinePrivacy()
                self?.navigationController?.popViewController(animated: true)
            })
        })
    }

    func sleepTimerSections() -> [Section] {
        let range = Double(SleepTimerSchedule.minimumDurationMinutes)...Double(SleepTimerSchedule.maximumDurationMinutes)
        var oneTime: [SettingsNativeRow] = []
        if case .oneTime = timerSnapshot.source {
            oneTime += activeTimerRows()
        } else {
            oneTime.append(.init(id: "settings.sleepTimer.oneTime.duration", title: L("Timer duration"), detail: L("%lld min", Int64(oneTimeDurationMinutes)), control: .stepper(Double(oneTimeDurationMinutes), range, { [weak self] in
                self?.oneTimeDurationMinutes = Int($0); self?.render()
            })))
            var start = action("settings.sleepTimer.oneTime.start", L("Start timer"), symbol: "timer") { [weak self] in
                guard let self else { return }
                self.sleepTimerServing?.startOneTime(durationMinutes: self.oneTimeDurationMinutes)
            }
            start.enabled = sleepTimerServing != nil
            oneTime.append(start)
        }
        var result = [Section(id: "oneTime", title: L("One-time timer"), rows: oneTime)]
        if case .automatic = timerSnapshot.source { result.append(.init(id: "activeAutomatic", title: L("Automatic timer"), rows: activeTimerRows())) }
        for (index, schedule) in viewModel.settings.playbackPreferences.sleepTimer.schedules.enumerated() {
            let id = "settings.sleepTimer.schedule.\(schedule.id)"
            var controls = [toggle(id + ".enabled", "\(L("Schedule")) \(index + 1)", value: schedule.isEnabled) { [weak self] in self?.viewModel.setSleepTimerScheduleEnabled($0, id: schedule.id) }]
            for isStart in [true, false] {
                let minute = isStart ? schedule.startMinute : schedule.endMinute
                let calendar = Calendar.autoupdatingCurrent
                let date = calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: Date())) ?? Date()
                controls.append(.init(id: id + (isStart ? ".from" : ".to"), title: L(isStart ? "From" : "To"), enabled: schedule.isEnabled && viewModel.canEditPlayback, control: .time(date, { [weak self] date in
                    let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                    guard let hour = parts.hour, let minute = parts.minute else { return }
                    if isStart { self?.viewModel.setSleepTimerScheduleStartMinute(hour * 60 + minute, id: schedule.id) }
                    else { self?.viewModel.setSleepTimerScheduleEndMinute(hour * 60 + minute, id: schedule.id) }
                })))
            }
            controls.append(.init(id: id + ".duration", title: L("Timer duration"), detail: L("%lld min", Int64(schedule.durationMinutes)), enabled: schedule.isEnabled && viewModel.canEditPlayback, control: .stepper(Double(schedule.durationMinutes), range, { [weak self] in self?.viewModel.setSleepTimerScheduleDuration(Int($0), id: schedule.id) })))
            controls.append(action(id + ".delete", L("Delete schedule"), destructive: true) { [weak self] in
                self?.confirm(title: L("Delete schedule"), message: "", button: L("Delete schedule")) { [weak self] in self?.viewModel.deleteSleepTimerSchedule(id: schedule.id) }
            })
            result.append(.init(id: id, title: "\(L("Schedule")) \(index + 1)", rows: controls))
        }
        result.append(.init(id: "addSchedule", title: L("Automatic schedules"), rows: [action("settings.sleepTimer.schedule.add", L("Add schedule"), symbol: "plus") { [weak self] in self?.viewModel.addSleepTimerSchedule() }]))
        return result
    }

    func activeTimerRows() -> [SettingsNativeRow] {
        let seconds = max(0, Int((timerSnapshot.deadline?.timeIntervalSinceNow ?? 0).rounded(.up)))
        return [text("settings.sleepTimer.active", L("Sleep timer"), detail: String(format: "%d:%02d", seconds / 60, seconds % 60)),
                text("settings.sleepTimer.endsAt", L("Ends at"), detail: timerSnapshot.deadline?.formatted(date: .omitted, time: .shortened) ?? ""),
                action("settings.sleepTimer.cancel", L("Cancel timer"), destructive: true) { [weak self] in self?.sleepTimerServing?.cancel() }]
    }

    func metadataSections() -> [Section] {
        let snapshot = detailState.metadata
        let preferences = viewModel.settings.importPreferences
        let visible = visibleMetadataProviders
        var metadata: [SettingsNativeRow] = []
        var operations: [SettingsNativeRow] = []
        for preference in visible {
            let provider = preference.provider
            let id = provider == .musicKit ? "settings.import.musicKitEnrichment" : "settings.import.metadataProvider.\(provider.rawValue).enabled"
            let status = snapshot.status(for: provider)
            var row = toggle(id, PrivacyProviderCatalog.descriptor(for: provider.rawValue).title, value: preferences.runtimeMetadataProviders.contains { $0.provider == provider && $0.isEnabled }) { [weak self] enabled in
                self?.activateProvider(id: provider.rawValue, enabled: enabled) { [weak self] in self?.viewModel.setMetadataProviderEnabled(provider, $0) }
            }
            row.enabled = status?.isRegistered == true && viewModel.canEditPlayback
            row.detail = status.map { providerStatusText($0) } ?? L("状态未知")
            metadata.append(row)
            if let status, status.isRegistered, status.authorization == .denied || status.authorization == .restricted {
                operations.append(action(provider == .musicKit ? "settings.import.musicKitAuthorization" : "settings.import.metadataProvider.\(provider.rawValue).authorization", L("重新请求权限")) { [weak self] in self?.viewModel.requestMetadataAuthorization(for: provider) })
            }

        }
        let scan = snapshot.scan
        if snapshot.isEnabled && snapshot.authorization == .authorized {
            operations.append(action(scan.status == .scanning ? "settings.import.musicKitCancel" : "settings.import.musicKitScan", L(scan.status == .scanning ? "取消扫描" : "扫描并补充")) { [weak self] in
                guard let self else { return }
                self.detailState.scanIntent = scan.status == .scanning ? .cancelling : .starting
                if scan.status == .scanning { self.viewModel.cancelMetadataScan() } else { self.viewModel.startMetadataScan() }
                self.detailState.metadata = self.viewModel.metadataEnrichmentSnapshot
            })
        } else { operations.append(text("metadata.unavailable", L("请先开启至少一个可用的元数据来源。"))) }
        if scan.status == .scanning {
            operations.append(text("settings.import.musicKitProgress", L("正在扫描 %d/%d", scan.processed, scan.total), detail: scan.currentTitle ?? "-"))
        } else if scan.status == .completed || scan.status == .cancelled {
            operations.append(text("metadata.summary", L("已处理 %d 首，匹配 %d 首，无匹配 %d 首，不确定 %d 首，失败 %d 首。", scan.processed, scan.matched, scan.noMatch, scan.ambiguous, scan.failed)))
        } else if scan.status == .failed { operations.append(text("metadata.failure", L("扫描未完成，请稍后重试。"))) }
        var result = [Section(id: "metadata", title: L("元数据"), footer: L("按启用顺序依次匹配；成功后停止。已有本地信息不会覆盖。"), rows: metadata),
                      Section(id: "metadataOperations", title: L("扫描与授权"), footer: L("只重试尚未匹配或未完成的歌曲，已成功匹配的歌曲会跳过。"), rows: operations)]
        if lyricsEnabled {
            var lyrics: [SettingsNativeRow] = visibleLyricsProviders.map { preference in
                toggle("settings.import.lyricsProvider.\(preference.provider.rawValue).enabled", PrivacyProviderCatalog.descriptor(for: preference.provider.rawValue).title, value: preferences.runtimeLyricsProviders.contains { $0.provider == preference.provider && $0.isEnabled }) { [weak self] enabled in
                    self?.activateProvider(id: preference.provider.rawValue, enabled: enabled) { [weak self] in self?.viewModel.setLyricsProviderEnabled(preference.provider, $0) }
                }
            }
            let preload = detailState.lyrics
            if viewModel.canPreloadLyrics && viewModel.hasEnabledLyricsProviders {
                lyrics.append(action(preload.status == .downloading ? "settings.import.lyricsPreloadCancel" : "settings.import.lyricsPreload", L(preload.status == .downloading ? "取消预下载" : "预下载歌词")) { [weak self] in
                    guard let self else { return }
                    self.detailState.lyricsIntent = preload.status == .downloading ? .cancelling : .starting
                    if preload.status == .downloading { self.viewModel.cancelLyricsPreload() } else { self.viewModel.startLyricsPreload() }
                    self.detailState.lyrics = self.viewModel.lyricsPreloadSnapshot
                })
            } else { lyrics.append(text("lyrics.unavailable", L("请先开启至少一个歌词来源，本地歌词仍可显示。"))) }
            if preload.status == .downloading { lyrics.append(text("settings.import.lyricsPreloadProgress", L("正在预下载 %d/%d", preload.processed, preload.total), detail: preload.currentTitle ?? "-")) }
            else if preload.status == .completed || preload.status == .cancelled { lyrics.append(text("lyrics.summary", L("已处理 %d 首，下载 %d 首，已有 %d 首，无歌词 %d 首，失败 %d 首。", preload.processed, preload.downloaded, preload.cached, preload.noLyrics, preload.failed))) }
            else if preload.status == .failed { lyrics.append(text("lyrics.failure", L("歌词预下载未完成，请稍后重试。"))) }
            result.append(.init(id: "lyrics", title: L("歌词"), footer: L("按启用顺序匹配歌词；播放页按需获取并保存，预下载只处理没有本地歌词的歌曲。"), rows: lyrics))
        }
        let pluginSettings = pluginRows(category: .metadata, destination: .importing)
        if !pluginSettings.isEmpty {
            result.append(.init(id: "metadataPlugins", title: L("插件"), rows: pluginSettings))
        }
        return result
    }

    func canReorderMetadata(at indexPath: IndexPath) -> Bool {
        guard case .metadata = page, viewModel.canEditPlayback,
              sections.indices.contains(indexPath.section) else { return false }
        return sections[indexPath.section].id == "metadata"
    }

    func reorderMetadata(from source: IndexPath, to destination: IndexPath) {
        guard canReorderMetadata(at: source), canReorderMetadata(at: destination) else { return }
        let visible = visibleMetadataProviders.map(\.provider)
        guard visible.indices.contains(source.row), visible.indices.contains(destination.row) else { return }
        viewModel.moveMetadataProviders(from: IndexSet(integer: source.row),
            to: destination.row > source.row ? destination.row + 1 : destination.row, within: visible)
        render()
    }

    open override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    open override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    open override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        guard canReorderMetadata(at: source) else { return source }
        let count = sections[source.section].rows.count
        let row = proposed.section < source.section ? 0 : (proposed.section > source.section ? count - 1 : proposed.row)
        return IndexPath(row: min(max(0, row), count - 1), section: source.section)
    }

    func providerStatusText(_ status: MetadataEnrichmentProviderSnapshot) -> String {
        guard status.isRegistered else { return L("尚未接入") }
        switch status.authorization {
        case .notDetermined: return L("未授权")
        case .authorized: return L("可用")
        case .denied: return L("权限已拒绝")
        case .restricted: return L("设备受限")
        case .unavailable: return L("不可用")
        }
    }

    func activateProvider(id: String, enabled: Bool, activate: @escaping (Bool) -> Void) {
        guard enabled else { activate(false); return }
        guard viewModel.isPrivacyPolicyAccepted else {
            presentPrivacy(.application, onAccept: { [weak self] in
                guard let self else { return }
                self.viewModel.acceptPrivacyPolicy()
                self.activateProvider(id: id, enabled: true, activate: activate)
            }, onDecline: { [weak self] in self?.viewModel.revokeOnlinePrivacy() })
            return
        }
        guard viewModel.settings.importPreferences.privacyPreferences.isProviderPolicyAccepted(id) else {
            presentPrivacy(.provider(PrivacyProviderCatalog.descriptor(for: id)), onAccept: { [weak self] in
                guard let self else { return }
                self.viewModel.acceptProviderPrivacy(for: id)
                Task { await self.viewModel.waitForPendingWork(); activate(true) }
            }, onDecline: { [weak self] in self?.viewModel.revokeProviderPrivacy(for: id) })
            return
        }
        activate(true)
    }

    func availabilitySections() -> [Section] {
        var controls = [toggle("settings.import.onlineSources.toggle", L("启用在线源服务"), value: viewModel.isPrivacyPolicyAccepted && viewModel.isOnlineSourcesEnabled) { [weak self] in self?.viewModel.setOnlineSourcesEnabled($0) }]
        controls[0].enabled = viewModel.isPrivacyPolicyAccepted && !viewModel.isSaving
        if !viewModel.isPrivacyPolicyAccepted { controls.append(text("availability.privacy", L("请先同意应用隐私政策，在线源服务会保持关闭。"))) }
        for configuration in viewModel.onlineSourceConfigurations {
            let accepted = isOnlineSourcePrivacyAccepted(configuration)
            var row = toggle("settings.import.onlineSource.\(configuration.sourceID.rawValue).enabled", configuration.displayName, value: configuration.isEnabled) { [weak self] in self?.viewModel.setOnlineSourceEnabled(configuration.sourceID, $0) }
            row.enabled = viewModel.isPrivacyPolicyAccepted && accepted && !viewModel.isSaving
            row.detail = onlineSourceProviderTitle(configuration.providerKind) + " · " + (!accepted ? L("需要先同意来源隐私协议") : (!configuration.isEnabled ? L("已关闭") : (viewModel.isOnlineSourcesEnabled ? L("已启用") : L("已启用，但总开关已关闭"))))
            controls.append(row)
        }
        if viewModel.onlineSourceConfigurations.isEmpty { controls.append(text("availability.empty", L("还没有配置在线源。请从在线源 Tab 添加来源。"))) }
        return [.init(id: "availability", title: L("在线源服务"), footer: L("总开关控制在线源服务；每个来源还可以独立启用或关闭。已经导入本地的媒体不受影响。"), rows: controls)]
    }

    func providerPrivacySections(_ descriptor: PrivacyProviderDescriptor) -> [Section] {
        var controls = [text("provider.service", L("服务"), detail: descriptor.service), text("provider.data", L("发送信息"), detail: descriptor.data), text("provider.purpose", L("用途"), detail: descriptor.purpose), text("provider.note", L("关闭 Provider 后不再发送新的请求；已经由第三方服务接收的请求日志由其隐私政策管理。"))]
        if let resource = descriptor.localHTMLResourceName {
            if descriptor.id == LyricsProviderID.lrclib.rawValue { controls.append(text("provider.lrclibNote", L("LRCLIB 未提供官方隐私协议；以下是应用提供的 Provider 隐私说明。"))) }
            controls.append(action("provider.policy", L("查看服务隐私政策"), disclosure: true) { [weak self] in self?.navigationController?.pushViewController(SettingsLocalPolicyViewController(resourceName: resource), animated: true) })
        } else if let url = descriptor.policyURL {
            controls.append(action("provider.policy", L("查看服务隐私政策")) { [weak self] in self?.present(SFSafariViewController(url: url), animated: true) })
        }
        let accepted = viewModel.settings.importPreferences.privacyPreferences.isProviderPolicyAccepted(descriptor.id)
        controls.append(text("provider.status", accepted ? L("Provider 隐私协议已同意") : L("请先同意应用隐私政策，才能启用此 Provider。")))
        var consent = action("settings.privacy.provider.\(descriptor.id)." + (accepted ? "revoke" : "accept"), L(accepted ? "撤回" : "同意"), destructive: accepted) { [weak self] in
            if accepted { self?.viewModel.revokeProviderPrivacy(for: descriptor.id) } else { self?.viewModel.acceptProviderPrivacy(for: descriptor.id) }
        }
        consent.enabled = !viewModel.isSaving && (accepted || viewModel.isPrivacyPolicyAccepted)
        controls.append(consent)
        return [.init(id: "providerPrivacy", title: L("Provider 隐私协议"), rows: controls)]
    }

    func sourcePrivacySections(_ initial: OnlineSourceConfiguration) -> [Section] {
        let configuration = viewModel.onlineSourceConfigurations.first { $0.sourceID == initial.sourceID } ?? initial
        let accepted = isOnlineSourcePrivacyAccepted(configuration)
        let data: String
        let purpose: String
        switch configuration.providerKind {
        case .dsAudio:
            data = L("你填写的 DS Audio 地址、账号和本次登录所需的认证信息，以及浏览、搜索、下载和临时试听所需的音频目录数据。验证码只在本次验证期间使用。")
            purpose = L("仅用于浏览来源目录、搜索音频、下载并导入本地媒体库，以及临时试听。")
        case .googleDrive:
            data = L("Google OAuth 会话和 Google Drive 文件目录、文件大小及下载所需的临时访问信息。令牌只存放在系统 Keychain；1.2.0 不进行 Google Drive 在线试听。")
            purpose = L("仅用于浏览 Google Drive 音频文件、下载并导入本地媒体库。")
        case .baiduPan:
            data = L("百度网盘来源配置和 Provider 实现实际需要的数据。当前版本未提供可用的百度网盘适配器。")
            purpose = L("仅用于未来 Provider 支持的在线源功能。")
        case .gateway:
            data = L("网关 Provider 实现声明的目录和访问数据。当前版本未提供可用的网关适配器。")
            purpose = L("仅用于未来 Provider 支持的在线源功能。")
        default:
            data = L("插件声明的来源目录与临时媒体访问数据。凭据只保存在系统 Keychain。")
            purpose = L("仅用于此插件注册并经你授权的来源功能。")
        }
        var consent = action("settings.privacy.onlineSource.\(configuration.sourceID.rawValue)." + (accepted ? "revoke" : "accept"), L(accepted ? "撤销并停用此来源" : "同意此来源隐私协议"), destructive: accepted) { [weak self] in
            guard let self else { return }
            if accepted {
                self.confirm(title: L("撤销来源隐私协议？"), message: L("撤销“%@”后会停止此来源的新请求并清除来源级同意；已经导入本地的媒体不会删除。", configuration.displayName), button: L("撤销并停用"), identifier: "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).revoke.confirm") { [weak self] in self?.viewModel.revokeOnlineSourcePrivacy(configuration.sourceID) }
            } else { self.viewModel.acceptOnlineSourcePrivacy(configuration.sourceID, policyVersion: configuration.providerKind.defaultPrivacyPolicyVersion) }
        }
        consent.enabled = !viewModel.isSaving && (accepted || viewModel.isPrivacyPolicyAccepted)
        return [.init(id: "sourcePrivacy", title: L("来源级隐私协议"), rows: [text("source.name", L("来源"), detail: configuration.displayName), text("source.type", L("来源类型"), detail: onlineSourceProviderTitle(configuration.providerKind)), text("source.version", L("协议版本"), detail: configuration.providerKind.defaultPrivacyPolicyVersion), text("source.data", L("会发送的数据"), detail: data), text("source.purpose", L("使用目的"), detail: purpose)]), .init(id: "sourceConsent", title: L("同意状态"), footer: L("撤销后立即停止此来源的新请求并清除来源级同意；已经导入本地的媒体不会删除。"), rows: [text("source.status", accepted ? L("来源隐私协议已同意") : L("首次进入此来源时会弹出协议；同意后才能浏览、试听或导入。")), consent])]
    }

    func presentPrivacy(_ disclosure: PrivacyDisclosure, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        let controller = SettingsPrivacyConsentViewController(disclosure: disclosure, onAccept: onAccept, onDecline: onDecline)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    func releaseSections() -> [Section] {
        guard !detailLoading else { return [.init(id: "releaseLoading", title: "", rows: [text("release.loading", L("加载发布信息"))])] }
        guard let releaseInfo else { return [.init(id: "releaseEmpty", title: "", rows: [text("release.empty", L("暂无发布信息"), detail: L("当前构建未提供只读发布清单。"))])] }
        var application: [SettingsNativeRow] = []
        if let version = nonEmpty(releaseInfo.appVersion) { application.append(text("release.version", L("版本"), detail: version)) }
        if let build = nonEmpty(releaseInfo.buildNumber) { application.append(text("release.build", L("构建"), detail: build)) }
        application.append(text("release.time", L("构建时间"), detail: BuildInfo.buildTime()))
        let dependencies = releaseInfo.dependencies.map { dependency in
            action("release.dependency.\(dependency.id)", dependency.name, detail: [dependency.version, dependency.license, dependency.kind.rawValue].compactMap { $0 }.joined(separator: " · "), disclosure: true) { [weak self] in
                guard let self else { return }; self.push(self.child(.license(dependency)), destination: .about)
            }
        }
        return [
            .init(id: "application", title: L("应用"), rows: application),
            .init(id: "dependencies", title: L("依赖许可"), rows: dependencies.isEmpty ? [text("release.noDependencies", L("暂无依赖清单"))] : dependencies)
        ]
    }

    func licenseSections(_ dependency: SettingsDependencyLicense) -> [Section] {
        var metadata = [text("license.name", L("名称"), detail: dependency.name)]
        let kind = dependency.kind == .source ? L("源码") : (dependency.kind == .binary ? L("二进制") : L("其他"))
        for (id, title, value) in [("version", L("版本"), dependency.version), ("license", L("许可"), dependency.license), ("kind", L("类型"), kind)] {
            if let value = nonEmpty(value) { metadata.append(text("license.\(id)", title, detail: value)) }
        }
        var materials: [SettingsNativeRow] = []
        for (id, title, value) in [("file", L("本地许可文件"), dependency.licenseFile), ("revision", L("源码修订"), dependency.revision), ("checksum", L("二进制校验"), dependency.checksum)] {
            if let value = nonEmpty(value) { materials.append(action("license.\(id)", title, detail: value) { UIPasteboard.general.string = value }) }
        }
        for (id, title, url) in [("source", L("源码"), dependency.sourceURL), ("materials", L("构建材料"), dependency.buildMaterialsURL), ("url", L("在线许可全文"), dependency.licenseURL)] {
            if let url { materials.append(action("license.\(id)", title) { [weak self] in self?.present(SFSafariViewController(url: url), animated: true) }) }
        }
        var result = [Section(id: "licenseMetadata", title: L("依赖"), rows: metadata), Section(id: "licenseMaterials", title: L("材料"), rows: materials.isEmpty ? [text("license.noMaterials", L("未提供材料链接"))] : materials)]
        if let license = nonEmpty(dependency.licenseText) { result.append(.init(id: "licenseText", title: L("许可全文"), rows: [action("license.text", license) { UIPasteboard.general.string = license }])) }
        return result
    }

    func diagnosticSections() -> [Section] {
        let status = MusicLogger.fileLogStatus()
        var result: [Section] = []
        if let failure = viewModel.lastFailure { result.append(.init(id: "diagnosticFailure", title: L("最近一次设置错误"), rows: [text("diagnostics.failure", failure.message, detail: failure.diagnosticCode)])) }
        var share = action("settings.diagnostics.shareFileLog", L(preparingLogShare ? "正在准备日志文件" : "分享日志文件"), symbol: "square.and.arrow.up") { [weak self] in self?.shareLog() }
        share.enabled = status.isAvailable && !preparingLogShare
        result.append(.init(id: "fileLog", title: L("文件日志"), footer: L("按大小滚动，最多保留当前文件和 1 个归档文件。"), rows: [toggle("settings.diagnostics.fileLogging", L("启用文件日志"), value: viewModel.isFileLoggingEnabled) { [weak self] in self?.viewModel.setFileLoggingEnabled($0) }, text("diagnostics.logSize", L("文件大小"), detail: bytes(status.byteCount)), text("diagnostics.logLimit", L("滚动上限"), detail: bytes(status.maximumByteCount)), text("diagnostics.logLocation", L("文件位置"), detail: MusicLogger.fileName), share]))
        let entries = diagnosticsSnapshot.entries.map { text("diagnostics.entry.\($0.id)", $0.message, detail: [$0.code, $0.timestamp?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: "\n")) }
        result.append(.init(id: "diagnosticRecords", title: L("记录"), rows: detailLoading ? [text("diagnostics.loading", L("加载诊断信息"))] : (entries.isEmpty ? [text("diagnostics.empty", L("暂无诊断记录"))] : entries)))
        return result
    }

    func shareLog() {
        guard !preparingLogShare else { return }
        preparingLogShare = true; render()
        detailTasks.append(Task { [weak self] in
            await MusicLogger.flushFileLog()
            guard !Task.isCancelled, let self else { return }
            self.preparingLogShare = false; self.render()
            let status = MusicLogger.fileLogStatus()
            guard let url = status.fileURL, status.byteCount > 0 else {
                let alert = UIAlertController(title: L("无法分享日志文件"), message: L("暂无可分享的日志文件"), preferredStyle: .alert)
                alert.addAction(.init(title: L("确定"), style: .default)); self.present(alert, animated: true); return
            }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
            self.present(share, animated: true)
        })
    }

    func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

@MainActor
final class SettingsLocalPolicyViewController: UIViewController, WKNavigationDelegate {
    private let resourceName: String
    private let webView = WKWebView()
    init(resourceName: String) { self.resourceName = resourceName; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("查看服务隐私政策")
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "html"),
           let template = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(MusicFreeLocalization.localizedHTML(template), baseURL: url.deletingLastPathComponent())
        }
        else { webView.loadHTMLString("<p>\(L("无法加载本地隐私说明"))</p>", baseURL: nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, !url.isFileURL,
              url.absoluteString != "about:blank" else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if ["http", "https"].contains(url.scheme?.lowercased()) { present(SFSafariViewController(url: url), animated: true) }
    }
}

@MainActor
final class SettingsPrivacyConsentViewController: UITableViewController {
    private let disclosure: PrivacyDisclosure
    private let onAccept: () -> Void
    private let onDecline: () -> Void
    private var entries: [(String, String)] = []
    init(disclosure: PrivacyDisclosure, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.disclosure = disclosure; self.onAccept = onAccept; self.onDecline = onDecline
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = disclosure.accessibilityIdentifier
        navigationItem.leftBarButtonItem = .init(title: L("不同意"), style: .plain, target: self, action: #selector(decline))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "settings.privacyDisclosure.decline"
        navigationItem.rightBarButtonItem = .init(title: L("同意并继续"), style: .done, target: self, action: #selector(accept))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "settings.privacyDisclosure.accept"
        switch disclosure {
        case .application:
            title = L("应用隐私政策")
            entries = [(L("应用隐私政策 v1.2.0"), L("本地播放器的基本播放功能不需要联网。DS Audio、Google Drive、元数据和歌词都属于可选的第三方服务，所有 Provider 默认关闭。")), ("", L("同意后，应用才会在你开启 Provider 时向对应服务发送歌曲匹配信息。应用不会主动上传音频文件、完整文件路径或整个音乐库。")), ("", L("网络服务通常可以获得请求 IP 地址和 User-Agent，并按照各自的隐私政策处理请求日志。匹配结果、封面和歌词会保存到本地资料库。")), (L("查看完整隐私政策"), PrivacyPolicyURLs.app.absoluteString)]
        case .provider(let descriptor):
            title = descriptor.title
            entries = [(L("服务"), descriptor.service), (L("发送信息"), descriptor.data), (L("用途"), descriptor.purpose), (L("查看服务隐私政策"), descriptor.policyURL?.absoluteString ?? "")]
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = entries[indexPath.row].0
        cell.detailTextLabel?.text = entries[indexPath.row].1
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.numberOfLines = 0
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row == entries.count - 1 else { return }
        switch disclosure {
        case .application: present(SFSafariViewController(url: PrivacyPolicyURLs.app), animated: true)
        case .provider(let descriptor):
            if let resource = descriptor.localHTMLResourceName { navigationController?.pushViewController(SettingsLocalPolicyViewController(resourceName: resource), animated: true) }
            else if let url = descriptor.policyURL { present(SFSafariViewController(url: url), animated: true) }
        }
    }
    @objc private func accept() { dismiss(animated: true, completion: onAccept) }
    @objc private func decline() { dismiss(animated: true, completion: onDecline) }
}
