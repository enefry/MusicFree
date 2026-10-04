import AppServices
import MusicDomain
import MediaSourceAPI
import SettingsAPI
import MusicFreePluginAPI
import SwiftUI

/// Host settings UI; no plugin can supply UIKit or own the player surface.
@MainActor public struct PluginSettingsView: View {
    let plugins: any PluginServing
    let settings: any SettingsServing
    @State private var snapshots: [PluginSnapshot] = []
    @State private var showHidden = false
    @State private var busy = false
    @State private var failure: String?
    @State private var policy: PluginSnapshot?
    @State private var analysis: PluginPCMAnalysisSnapshot?
    public init(plugins: any PluginServing, settings: any SettingsServing) {
        self.plugins = plugins; self.settings = settings
    }
    public var body: some View {
        List {
            ForEach(snapshots.filter { showHidden || $0.preference.isVisible }) { snapshot in
                Section(snapshot.descriptor.name) {
                    Text(status(snapshot.state)).foregroundStyle(.secondary)
                    if let diagnostic = snapshot.diagnostic { Text(diagnostic).font(.footnote).foregroundStyle(.red) }
                    Toggle("显示入口", isOn: binding(snapshot, \.isVisible))
                    Toggle("启用能力", isOn: binding(snapshot, \.isEnabled))
                        .accessibilityIdentifier("plugins.\(snapshot.id.rawValue).enabled")
                    Toggle("允许加载", isOn: binding(snapshot, \.isLoadAllowed))
                        .accessibilityIdentifier("plugins.\(snapshot.id.rawValue).loadAllowed")
                    if !snapshot.descriptor.permissions.isEmpty || snapshot.descriptor.kinds.contains(.lyrics) || snapshot.descriptor.kinds.contains(.metadata) {
                        Button("服务许可") { policy = snapshot }
                        Button("撤销许可", role: .destructive) { revoke(snapshot) }
                    }
                    NavigationLink("配置") {
                        PluginConfigurationEditor(descriptor: snapshot.descriptor, initial: snapshot.preference.configuration) { values in
                            await mutate(snapshot.id) { preference in preference.configuration = values }
                        }
                    }
                    .disabled(snapshot.state == .compiledOut || snapshot.state == .incompatible || snapshot.state == .invalidRegistration)
                    if snapshot.descriptor.kinds.contains(.onlineSource) {
                        NavigationLink("账户与来源") {
                            PluginSourceSettingsView(descriptor: snapshot.descriptor, settings: settings, plugins: plugins)
                        }
                        .accessibilityIdentifier("plugins.\(snapshot.id.rawValue).sources")
                    }
                    if snapshot.descriptor.kinds.contains(.dsp) {
                        if let options = snapshot.descriptor.dspPlacements {
                            Picker("处理位置", selection: placementBinding(snapshot)) {
                                ForEach(PluginDSPPlacement.known.filter { options.supported.contains($0) }, id: \.self) { placement in
                                    Text(placement == .perTrack ? "每轨混音前" : "总线混音后").tag(placement)
                                }
                                if let selected = snapshot.preference.dspPlacement, !options.supported.contains(selected) {
                                    Text("不支持的位置：\(selected.rawValue)").tag(selected)
                                }
                            }
                            .accessibilityIdentifier("plugins.\(snapshot.id.rawValue).placement")
                            .disabled([.compiledOut, .incompatible, .invalidRegistration].contains(snapshot.state))
                        }
                        Text("每轨分别处理后混音；总线处理混音后的声音。更改位置在暂停或停止后生效，每个播放会话使用独立实例。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let analysis {
                            LabeledContent("音频峰值", value: analysis.peak.formatted(.number.precision(.fractionLength(3))))
                            LabeledContent("音频 RMS", value: analysis.rms.formatted(.number.precision(.fractionLength(3))))
                        }
                    }
                }
            }
            Section {
                Toggle("管理隐藏插件", isOn: $showHidden)
                Text("隐藏入口不会停止已经启用的能力。启用与允许加载分别控制运行；外部服务还需要相应许可。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
        }
        .disabled(busy)
        .navigationTitle("插件")
        .accessibilityIdentifier("settings.plugins")
        .task { snapshots = await plugins.snapshots() }
        .task {
            for await value in await plugins.audioAnalysis() {
                guard !Task.isCancelled else { return }
                analysis = value
            }
        }
        .confirmationDialog("服务许可", isPresented: Binding(get: { policy != nil }, set: { if !$0 { policy = nil } }), titleVisibility: .visible) {
            if let snapshot = policy {
                Button("同意并授权") { grant(snapshot); policy = nil }
            }
            Button("取消", role: .cancel) { policy = nil }
        } message: {
            if let snapshot = policy {
                Text(snapshot.descriptor.permissions.contains(.network)
                     ? "此服务可发送歌曲查询和来源访问请求；凭据由系统 Keychain 保存。已经发送的请求无法撤回。"
                     : "此参考服务使用离线数据。宿主的歌词和歌曲信息同意记录将保留用于服务运行。")
            }
        }
    }
    private func binding(_ snapshot: PluginSnapshot, _ key: WritableKeyPath<PluginPreference, Bool>) -> Binding<Bool> {
        Binding(get: { snapshots.first { $0.id == snapshot.id }?.preference[keyPath: key] ?? false }, set: { value in
            Task { await mutate(snapshot.id) { $0[keyPath: key] = value } }
        })
    }
    private func placementBinding(_ snapshot: PluginSnapshot) -> Binding<PluginDSPPlacement> {
        Binding(get: {
            snapshots.first { $0.id == snapshot.id }?.preference.dspPlacement
                ?? snapshot.descriptor.dspPlacements?.defaultPlacement ?? .perTrack
        }, set: { placement in
            Task { await mutate(snapshot.id) { $0.dspPlacement = placement } }
        })
    }
    private func mutate(_ id: PluginID, edit: (inout PluginPreference) -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let current = try await settings.load()
            var preferences = current.pluginPreferences
            let index = preferences.firstIndex { $0.pluginID == id }
            var preference = index.map { preferences[$0] } ?? PluginPreference(pluginID: id)
            edit(&preference)
            if let snapshot = snapshots.first(where: { $0.id == id }),
               ![.compiledOut, .incompatible, .invalidRegistration].contains(snapshot.state) {
                try snapshot.descriptor.configuration.validate(preference.configuration, credentialRecordID: preference.credentialRecordID)
            }
            if let index { preferences[index] = preference } else { preferences.append(preference) }
            let updated = current.settingPluginPreferences(preferences)
            try await settings.update(updated); await plugins.apply(updated)
            snapshots = await plugins.snapshots(); failure = nil
        } catch { failure = "插件设置保存失败。请检查配置后重试。" }
    }
    private func grant(_ snapshot: PluginSnapshot) {
        Task {
            guard !busy else { return }; busy = true; defer { busy = false }
            do {
                let current = try await settings.load()
                let updated = PluginConsentSettings.grant(descriptor: snapshot.descriptor, current: current)
                try await settings.update(updated); await plugins.apply(updated)
                snapshots = await plugins.snapshots(); failure = nil
            } catch { failure = "服务许可保存失败。" }
        }
    }
    private func revoke(_ snapshot: PluginSnapshot) {
        Task {
            guard !busy else { return }; busy = true; defer { busy = false }
            do {
                let current = try await settings.load()
                let updated = PluginConsentSettings.revoke(descriptor: snapshot.descriptor, current: current)
                try await settings.update(updated); await plugins.apply(updated)
                snapshots = await plugins.snapshots(); failure = nil
            } catch { failure = "服务许可撤销失败。" }
        }
    }
    private func status(_ state: PluginLifecycleState) -> String {
        switch state {
        case .disabled: "已停用"
        case .loadBlocked: "尚未允许加载"
        case .permissionRequired: "需要许可"
        case .registered: "已注册，按需加载"
        case .loading: "加载中"
        case .ready: "可用"
        case .running: "运行中"
        case .compiledOut: "当前构建未包含"
        case .incompatible: "版本不兼容，配置已保留"
        case .invalidRegistration: "注册不可用"
        case .failed: "加载失败"
        case .unloaded: "已卸载"
        }
    }
}

@MainActor struct PluginConfigurationEditor: View {
    let descriptor: PluginDescriptor
    let onSave: ([String: PluginConfigurationValue]) async -> Void
    @State private var values: [String: PluginConfigurationValue]
    @State private var busy = false
    @State private var failure: String?
    init(descriptor: PluginDescriptor, initial: [String: PluginConfigurationValue], onSave: @escaping ([String: PluginConfigurationValue]) async -> Void) {
        self.descriptor = descriptor; self.onSave = onSave; _values = State(initialValue: initial)
    }
    var body: some View {
        Form {
            PluginConfigurationFields(schema: descriptor.configuration, values: $values)
            Button("保存配置") {
                Task {
                    busy = true; defer { busy = false }
                    do {
                        try descriptor.configuration.validate(values, credentialRecordID: nil)
                        failure = nil
                        await onSave(values)
                    } catch { failure = "配置无效，请检查必填项及数值范围。" }
                }
            }
                .disabled(busy)
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("配置")
    }
}
@MainActor struct PluginConfigurationFields: View {
    let schema: PluginConfigurationSchema
    @Binding var values: [String: PluginConfigurationValue]
    var body: some View {
        ForEach(schema.fields.filter { $0.kind != .secret }) { field in
            switch field.kind {
            case .text:
                TextField(field.title, text: Binding(get: { if case .text(let value) = values[field.id] { value } else { "" } },
                    set: { values[field.id] = .text($0) }))
            case .number:
                TextField(field.title, value: Binding(get: { if case .number(let value) = values[field.id] { value } else { 1.0 } },
                    set: { values[field.id] = .number($0) }), format: .number)
            case .flag:
                Toggle(field.title, isOn: Binding(get: { if case .flag(let value) = values[field.id] { value } else { false } },
                    set: { values[field.id] = .flag($0) }))
            case .secret: EmptyView()
            }
        }
    }
}
