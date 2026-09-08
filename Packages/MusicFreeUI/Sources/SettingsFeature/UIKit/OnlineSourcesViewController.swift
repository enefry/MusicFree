import AppServices
import DesignSystem
import MediaSourceAPI
import MusicDomain
import UIKit

/// Native UIKit online-source browser. The source model is shared with the
/// Settings feature, but this route no longer embeds the SwiftUI scene.
@MainActor
public final class OnlineSourcesViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate
{
    /// Regular-width shells render the selected source in the app detail
    /// column. Compact shells leave this unset and keep the normal push stack.
    public var onSelectDetail: ((UIViewController) -> Void)?

    private let model: OnlineSourcesSceneModel
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var refreshTask: Task<Void, Never>?
    private var downloadObservationTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var lastApplicationPrivacyAccepted: Bool?
    private var lastRenderSignature: String?
    private var lastRenderedDownloadQueueTaskCount: Int?

    public init(model: OnlineSourcesSceneModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = L("onlineSources.title")
        restorationIdentifier = "onlineSources.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "onlineSources.list"
        navigationItem.largeTitleDisplayMode = .always
        let addButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: nil,
            action: nil
        )
        addButton.menu = makeAddSourceMenu()
        addButton.accessibilityLabel = L("添加在线源")
        addButton.accessibilityIdentifier = "onlineSources.add"
        navigationItem.rightBarButtonItem = addButton
        configureTableView()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await model.start()
            render()
            observeModel()
            presentApplicationPrivacyIfVisible()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A tab controller keeps non-selected child views attached to the
        // window on iOS 26. `view.window != nil` therefore does not prove that
        // this route is visible. If privacy is revoked while Settings is
        // selected, defer the disclosure until Online Sources is actually
        // selected again.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.start()
            // Settings writes are serialized independently from the online
            // source runtime stream. Give the settings worker one turn to
            // finish before rendering a source detail after tab switching.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await model.refreshPersistedState()
            render(force: true)
            presentApplicationPrivacyIfVisible()
        }
    }

    deinit {
        refreshTask?.cancel()
        downloadObservationTask?.cancel()
        startTask?.cancel()
    }

    public override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        tableView
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "OnlineSourceCell")
        tableView.accessibilityIdentifier = "onlineSources.list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func observeModel() {
        refreshTask?.cancel()
        downloadObservationTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.model.serving.makeSnapshotStream()
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self.render()
                await self.presentPendingAuthenticationIfNeeded()
            }
        }
        downloadObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = model.downloadQueue.makeSnapshotStream()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self.refreshDownloadQueueSummary(snapshot)
            }
        }
    }

    private func render(force: Bool = false) {
        let wasAccepted = lastApplicationPrivacyAccepted
        let isAccepted = model.snapshot.isApplicationPrivacyAccepted
        lastApplicationPrivacyAccepted = isAccepted
        let signature = presentationSignature
        guard force || signature != lastRenderSignature else { return }
        lastRenderSignature = signature
        tableView.reloadData()
        lastRenderedDownloadQueueTaskCount = model.downloadQueue.snapshot.activeTaskCount
        if wasAccepted == true, !isAccepted {
            presentApplicationPrivacyIfVisible()
        }
    }

    private func refreshDownloadQueueSummary(_ snapshot: OnlineDownloadQueueSnapshot) {
        let nextCount = snapshot.activeTaskCount
        guard nextCount != lastRenderedDownloadQueueTaskCount else { return }
        lastRenderedDownloadQueueTaskCount = nextCount
        guard isViewLoaded,
              tableView.numberOfSections > 0,
              tableView.numberOfRows(inSection: 0) > 0
        else { return }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
    }

    private func presentApplicationPrivacyIfVisible() {
        guard !model.snapshot.isApplicationPrivacyAccepted,
              viewIfLoaded?.window != nil,
              navigationController?.topViewController === self,
              presentedViewController == nil
        else { return }

        if let tabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            let routeController = navigationController ?? self
            guard selectedViewController === routeController else { return }
        }

        presentApplicationPrivacy()
    }

    private var presentationSignature: String {
        let sources = sourceRows.map { summary in
            [
                summary.sourceID.rawValue,
                summary.displayName,
                summary.providerKind.rawValue,
                summary.privacyPolicyVersion,
                String(summary.isRegistered),
                String(summary.isPrivacyAccepted),
                String(summary.isEnabled),
                String(summary.isRuntimeEnabled),
                String(describing: summary.capabilities),
            ].joined(separator: "|")
        }.joined(separator: "#")
        return [
            String(model.snapshot.isApplicationPrivacyAccepted),
            String(model.snapshot.isGloballyEnabled),
            sources,
        ].joined(separator: "::")
    }

    private var sourceRows: [OnlineSourceSummary] {
        model.snapshot.sources.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func makeAddSourceMenu() -> UIMenu {
        var actions = [UIAction(
            title: L("DS Audio"),
            image: UIImage(systemName: "externaldrive.connected.to.line.below")
        ) { [weak self] _ in
            self?.beginAdding(providerKind: .dsAudio)
        }]
        if model.isGoogleDriveOAuthConfigured {
            actions.append(UIAction(
                title: L("Google Drive"),
                image: UIImage(systemName: "externaldrive")
            ) { [weak self] _ in
                self?.beginAdding(providerKind: .googleDrive)
            })
        }
        return UIMenu(title: L("添加在线源"), children: actions)
    }

    private func beginAdding(providerKind: OnlineProviderKind) {
        guard model.snapshot.isApplicationPrivacyAccepted else {
            presentApplicationPrivacy { [weak self] in
                self?.presentAddForm(providerKind: providerKind)
            }
            return
        }
        presentAddForm(providerKind: providerKind)
    }

    private func presentApplicationPrivacy(
        afterAcceptance: (() -> Void)? = nil
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("应用隐私协议"),
            message: L("第一次进入在线源或添加来源前，需要允许应用为你配置的来源发起浏览、下载和试听请求。远程 URL、Token、Cookie、Header 和播放器访问对象只在一次操作期间使用，不会写入设置、播放队列或日志。"),
            preferredStyle: .alert
        )
        let cancelAction = UIAlertAction(title: L("取消"), style: .cancel)
        cancelAction.accessibilityIdentifier = "onlineSources.applicationPrivacy.cancel"
        alert.addAction(cancelAction)
        let confirmAction = UIAlertAction(title: L("同意"), style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = await model.acceptApplicationPrivacy()
                // UIAlertController dismisses itself after the action handler
                // returns. Do not present the provider form in the same turn:
                // UIKit can reject the second presentation or leave the
                // privacy alert visually stacked above it.
                await waitForPresentedControllerDismissal()
                guard !Task.isCancelled else { return }
                render(force: true)
                if accepted,
                   presentedViewController == nil,
                   navigationController?.topViewController === self {
                    afterAcceptance?()
                } else if !accepted {
                    presentModelErrorIfNeeded()
                }
            }
        }
        confirmAction.accessibilityIdentifier = "onlineSources.applicationPrivacy.confirm"
        alert.addAction(confirmAction)
        alert.view.accessibilityIdentifier = "onlineSources.applicationPrivacy.sheet"
        present(alert, animated: true)
    }

    private func presentAddForm(providerKind: OnlineProviderKind) {
        guard providerKind != .dsAudio else {
            presentDSAudioAddForm()
            return
        }
        let alert = UIAlertController(title: L("添加在线源"), message: L("请填写来源配置"), preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L("显示名称")
            field.accessibilityIdentifier = "onlineSources.add.displayName"
        }
        alert.addTextField { field in
            field.placeholder = providerKind == .dsAudio ? L("DS Audio 地址") : L("服务地址（可选）")
            field.keyboardType = .URL
            field.accessibilityIdentifier = "onlineSources.add.endpoint"
        }
        if providerKind == .dsAudio {
            alert.addTextField { field in
                field.placeholder = L("DS Audio 账号")
                field.accessibilityIdentifier = "onlineSources.add.account"
            }
            alert.addTextField { field in
                field.placeholder = L("DS Audio 密码")
                field.isSecureTextEntry = true
                field.accessibilityIdentifier = "onlineSources.add.password"
            }
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("添加"), style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let name = alert.textFields?.first?.text ?? ""
            let endpoint = alert.textFields?.dropFirst().first?.text ?? ""
            let account = providerKind == .dsAudio ? alert.textFields?.dropFirst(2).first?.text ?? "" : ""
            let password = providerKind == .dsAudio ? alert.textFields?.dropFirst(3).first?.text ?? "" : ""
            let sourceID = MediaSourceID("\(providerKind.rawValue).\(UUID().uuidString.lowercased())")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await model.addSource(
                    sourceID: sourceID,
                    deviceName: "MusicFree-\(UUID().uuidString.lowercased())",
                    providerKind: providerKind,
                    displayName: name,
                    endpointText: endpoint,
                    account: account,
                    password: password
                )
                render()
                switch result {
                case .added:
                    break
                case .verificationRequired:
                    presentOneTimeCode(for: sourceID)
                case let .failed(message):
                    presentMessage(title: L("无法添加在线源"), message: message)
                }
            }
        })
        alert.view.accessibilityIdentifier = "onlineSources.add.sheet"
        present(alert, animated: true)
    }

    private func presentDSAudioAddForm() {
        let controller = DSAudioAddSourceViewController(model: model) { [weak self] in
            self?.render(force: true)
        }
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
        present(navigationController, animated: true)
    }

    private func presentOneTimeCode(for sourceID: MediaSourceID) {
        let controller = DSAudioOneTimeCodeViewController(
            message: model.authenticationFailureMessage,
            verify: { [weak self] code in
                guard let self else { return false }
                return await model.authenticateWithOneTimeCode(
                    sourceID: sourceID,
                    code: code
                )
            },
            failureMessage: { [weak self] in
                self?.model.authenticationFailureMessage
            },
            onVerified: { [weak self] in
                self?.render(force: true)
                self?.presentModelErrorIfNeeded()
            },
            onCancelled: { [weak self] in
                self?.model.cancelAuthenticationChallenge()
            }
        )
        presentDSAudioSheet(controller, from: self)
    }

    private func presentPendingAuthenticationIfNeeded() async {
        guard let sourceID = model.authenticationChallengeSourceID,
              viewIfLoaded?.window != nil,
              navigationController?.topViewController === self,
              presentedViewController == nil
        else { return }

        // In the regular three-column shell the list and catalog are visible
        // at the same time. Let the active catalog own an in-place reconnect
        // challenge instead of presenting a duplicate alert from the content
        // column.
        if let detailNavigationController = splitViewController?
            .viewController(for: .secondary) as? UINavigationController,
           detailNavigationController.topViewController
            is OnlineSourceCatalogViewController {
            return
        }

        if let tabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            let routeController = navigationController ?? self
            guard selectedViewController === routeController else { return }
        }
        presentOneTimeCode(for: sourceID)
    }

    private func presentModelErrorIfNeeded() {
        guard let message = model.lastError else { return }
        model.clearError()
        presentMessage(title: L("在线源操作失败"), message: message)
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    public func numberOfSections(in _: UITableView) -> Int { 2 }

    public func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : sourceRows.count
    }

    public func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? L("任务") : L("在线源")
    }

    public func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        nil
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OnlineSourceCell", for: indexPath)
        // Every section intentionally shares the same basic cell class. Reset
        // mutually exclusive accessory and accessibility state before
        // configuring it; otherwise a recycled source row leaves its UISwitch
        // attached to the download-queue row, making that navigation row look
        // disabled and preventing it from being exposed as a button.
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.accessibilityTraits = []
        cell.isUserInteractionEnabled = true
        cell.selectionStyle = .default
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = L("下载任务")
            content.secondaryText = model.downloadQueue.snapshot.activeTaskCount > 0
                ? L("进行中：%d", model.downloadQueue.snapshot.activeTaskCount)
                : L("暂无进行中的任务")
            content.image = UIImage(systemName: "arrow.down.circle")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "onlineSources.downloadQueue"
            cell.accessibilityTraits = .button
        } else {
            let summary = sourceRows[indexPath.row]
            content.text = summary.displayName
            content.secondaryText = nil
            content.image = UIImage(systemName: providerSymbol(summary.providerKind))
            content.imageProperties.tintColor = MusicFreeUIColorTokens.accent
            cell.accessibilityIdentifier = "onlineSources.source.\(summary.sourceID.rawValue)"
            cell.accessibilityValue = sourceStatus(summary)
            if summary.isRegistered,
               summary.isPrivacyAccepted,
               !summary.isEnabled {
                let enableSwitch = UISwitch()
                enableSwitch.isOn = false
                cell.selectionStyle = .none
                enableSwitch.accessibilityLabel = L("启用在线源")
                enableSwitch.accessibilityIdentifier =
                    "onlineSources.source.\(summary.sourceID.rawValue).enabled"
                enableSwitch.addAction(UIAction { [weak self, weak enableSwitch] _ in
                    guard let self, let enableSwitch, enableSwitch.isOn else { return }
                    enableSwitch.isEnabled = false
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await model.setSourceEnabled(summary.sourceID, isEnabled: true)
                        render(force: true)
                        presentModelErrorIfNeeded()
                    }
                }, for: .valueChanged)
                cell.accessoryView = enableSwitch
            } else {
                cell.accessoryType = .disclosureIndicator
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    public func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let queueController = OnlineSourceDownloadQueueViewController(model: model)
            if let onSelectDetail {
                onSelectDetail(queueController)
            } else {
                navigationController?.pushViewController(queueController, animated: true)
            }
            return
        }
        let summary = sourceRows[indexPath.row]
        guard summary.isRegistered else {
            presentMessage(title: L("在线源不可用"), message: L("此来源当前没有可用的 Provider。"))
            return
        }
        guard summary.isPrivacyAccepted else {
            presentSourcePrivacy(for: summary)
            return
        }
        // A disabled source exposes only its one-way enable affordance in the
        // list. Do not push an empty catalog that can never load until the
        // source is enabled from that switch or Settings.
        guard summary.isEnabled else { return }
        openCatalog(for: summary)
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let summary = sourceRows[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L("删除")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            let alert = UIAlertController(title: L("删除在线源？"), message: L("已下载并导入本地的媒体不会删除。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in completion(false) })
            alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { completion(false); return }
                    _ = await model.removeSource(summary.sourceID)
                    render()
                    completion(true)
                }
            })
            present(alert, animated: true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func presentSourcePrivacy(for summary: OnlineSourceSummary) {
        let alert = UIAlertController(title: L("来源隐私协议"), message: L("来源：%@\n协议版本：%@\n协议用于浏览、下载和临时试听所需的远程目录数据。撤销后会立即停止此来源操作。", summary.displayName, summary.privacyPolicyVersion), preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: L("取消"), style: .cancel)
        cancelAction.accessibilityIdentifier = "onlineSources.sourcePrivacy.close"
        alert.addAction(cancelAction)
        let confirmAction = UIAlertAction(title: L("同意"), style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = await model.acceptSourcePrivacy(summary.sourceID)
                render()
                if accepted {
                    await waitForPresentedControllerDismissal()
                    guard navigationController?.topViewController === self else { return }
                    openCatalog(for: summary)
                }
            }
        }
        confirmAction.accessibilityIdentifier = "onlineSources.source.\(summary.sourceID.rawValue).privacy.accept.confirm"
        alert.addAction(confirmAction)
        alert.view.accessibilityIdentifier = "onlineSources.source.\(summary.sourceID.rawValue).privacy.sheet"
        present(alert, animated: true)
    }

    private func waitForPresentedControllerDismissal() async {
        for _ in 0..<30 {
            guard presentedViewController != nil
                    || transitionCoordinator != nil
            else {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func openCatalog(for summary: OnlineSourceSummary) {
        let catalogController = OnlineSourceCatalogViewController(
            model: model,
            sourceID: summary.sourceID,
            title: summary.displayName
        )
        if let onSelectDetail {
            onSelectDetail(catalogController)
        } else {
            navigationController?.pushViewController(catalogController, animated: true)
        }
    }

    private func providerTitle(_ kind: OnlineProviderKind) -> String {
        switch kind {
        case .dsAudio: L("DS Audio")
        case .googleDrive: L("Google Drive")
        case .baiduPan: L("百度网盘")
        case .gateway: L("网关")
        }
    }

    private func providerSymbol(_ kind: OnlineProviderKind) -> String {
        switch kind {
        case .dsAudio: "externaldrive.connected.to.line.below"
        case .googleDrive: "externaldrive"
        case .baiduPan: "cloud"
        case .gateway: "network"
        }
    }

    private func sourceStatus(_ summary: OnlineSourceSummary) -> String {
        if !summary.isRegistered { return L("未接入") }
        if !summary.isPrivacyAccepted { return L("待同意") }
        if !summary.isEnabled { return L("已停用") }
        if !summary.isRuntimeEnabled { return L("已关闭") }
        return L("可用")
    }
}

@MainActor
private final class DSAudioAddSourceViewController: UIViewController {
    private let model: OnlineSourcesSceneModel
    private let onAdded: () -> Void
    private let sourceID = MediaSourceID(
        "dsaudio.\(UUID().uuidString.lowercased())"
    )
    private let deviceName = "MusicFree-\(UUID().uuidString.lowercased())"

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let displayNameField = UITextField()
    private let endpointField = UITextField()
    private let accountField = UITextField()
    private let passwordField = UITextField()
    private let oneTimeCodeField = UITextField()
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private let diagnosticLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let submitButton = UIButton(type: .system)
    private var submitTask: Task<Void, Never>?

    init(model: OnlineSourcesSceneModel, onAdded: @escaping () -> Void) {
        self.model = model
        self.onAdded = onAdded
        super.init(nibName: nil, bundle: nil)
        title = L("添加 DS Audio")
        restorationIdentifier = "onlineSources.dsaudio.add"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "onlineSources.dsaudio.add"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "onlineSources.dsaudio.add.cancel"

        configureFields()
        configureLayout()
        updateSubmissionState(isSubmitting: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        displayNameField.becomeFirstResponder()
    }

    deinit {
        submitTask?.cancel()
    }

    private func configureFields() {
        configureField(
            displayNameField,
            placeholder: L("例如：家庭 NAS"),
            identifier: "onlineSources.dsaudio.add.displayName"
        )
        displayNameField.textContentType = .name

        configureField(
            endpointField,
            placeholder: L("DS Audio 地址，例如 https://nas.example.com:5001"),
            identifier: "onlineSources.dsaudio.add.endpoint"
        )
        endpointField.keyboardType = .URL
        endpointField.autocapitalizationType = .none
        endpointField.autocorrectionType = .no
        endpointField.textContentType = .URL

        configureField(
            accountField,
            placeholder: L("DSM 账号"),
            identifier: "onlineSources.dsaudio.add.account"
        )
        accountField.textContentType = .username
        accountField.autocapitalizationType = .none
        accountField.autocorrectionType = .no

        configureField(
            passwordField,
            placeholder: L("DSM 密码"),
            identifier: "onlineSources.dsaudio.add.password"
        )
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password

        configureField(
            oneTimeCodeField,
            placeholder: L("验证码（如 DSM 要求）"),
            identifier: "onlineSources.dsaudio.add.oneTimeCode"
        )
        oneTimeCodeField.keyboardType = .numberPad
        oneTimeCodeField.textContentType = .oneTimeCode
        oneTimeCodeField.autocorrectionType = .no

        statusLabel.font = MusicFreeUIFontTokens.caption
        statusLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        statusLabel.numberOfLines = 0
        statusLabel.text = L("验证码默认显示；如果 DSM 未启用二次验证可以留空。")
        statusLabel.accessibilityIdentifier = "onlineSources.dsaudio.add.status"

        errorLabel.font = MusicFreeUIFontTokens.caption
        errorLabel.textColor = MusicFreeUIColorTokens.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "onlineSources.dsaudio.add.error"

        diagnosticLabel.font = MusicFreeUIFontTokens.caption
        diagnosticLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        diagnosticLabel.numberOfLines = 0
        diagnosticLabel.isHidden = true
        diagnosticLabel.accessibilityIdentifier = "onlineSources.dsaudio.add.diagnostic"

        var configuration = UIButton.Configuration.filled()
        configuration.title = L("添加并连接")
        configuration.image = UIImage(systemName: "link")
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        submitButton.configuration = configuration
        submitButton.accessibilityIdentifier = "onlineSources.dsaudio.add.submit"
        submitButton.addAction(UIAction { [weak self] _ in
            self?.submit()
        }, for: .touchUpInside)
    }

    private func configureField(
        _ field: UITextField,
        placeholder: String,
        identifier: String
    ) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        field.accessibilityIdentifier = identifier
        field.heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.accessibilityIdentifier = "onlineSources.dsaudio.add.scroll"

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.medium
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.large,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.large,
            trailing: MusicFreeSpacingTokens.large
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let heading = makeTextStack(
            title: L("连接你的 DS Audio"),
            subtitle: L("完成一次授权后，来源会保存在在线源列表中。后续可以浏览文件夹、试听和下载导入。")
        )
        contentStack.addArrangedSubview(heading)
        contentStack.addArrangedSubview(makeFieldGroup(title: L("名称"), field: displayNameField))
        contentStack.addArrangedSubview(makeFieldGroup(title: L("地址"), field: endpointField))
        contentStack.addArrangedSubview(makeFieldGroup(title: L("账号"), field: accountField))
        contentStack.addArrangedSubview(makeFieldGroup(title: L("密码"), field: passwordField))
        contentStack.addArrangedSubview(makeFieldGroup(title: L("验证码"), field: oneTimeCodeField))
        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(diagnosticLabel)

        let buttonRow = UIStackView(arrangedSubviews: [activityIndicator, submitButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.spacing = MusicFreeSpacingTokens.small
        contentStack.addArrangedSubview(buttonRow)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func makeFieldGroup(title: String, field: UITextField) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = MusicFreeUIFontTokens.caption
        label.textColor = MusicFreeUIColorTokens.foregroundSecondary
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.xSmall
        return stack
    }

    private func makeTextStack(title: String, subtitle: String) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = MusicFreeUIFontTokens.preferred(.title2, weight: .bold)
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = MusicFreeUIFontTokens.secondary
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = MusicFreeSpacingTokens.xSmall
        return stack
    }

    @objc private func cancel() {
        submitTask?.cancel()
        dismiss(animated: true)
    }

    private func submit() {
        guard !isSubmitting else { return }
        view.endEditing(true)
        clearError()

        let displayName = displayNameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = endpointField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = accountField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = passwordField.text ?? ""
        let oneTimeCode = oneTimeCodeField.text?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !displayName.isEmpty else {
            showError(L("请输入来源名称。"), focus: displayNameField)
            return
        }
        guard let endpointURL = URL(string: endpoint),
              let components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil
        else {
            showError(L("请输入有效的 HTTP 或 HTTPS 地址。"), focus: endpointField)
            return
        }
        guard !account.isEmpty else {
            showError(L("请输入 DSM 账号。"), focus: accountField)
            return
        }
        guard !password.isEmpty else {
            showError(L("请输入 DSM 密码。"), focus: passwordField)
            return
        }

        updateSubmissionState(isSubmitting: true)
        submitTask?.cancel()
        submitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let normalizedCode = oneTimeCode?.isEmpty == false ? oneTimeCode : nil
            if model.authenticationChallengeSourceID == sourceID,
               let normalizedCode {
                let completed = await model.authenticateWithOneTimeCode(
                    sourceID: sourceID,
                    code: normalizedCode
                )
                guard !Task.isCancelled else { return }
                if completed {
                    finishSuccessfully()
                } else {
                    showError(
                        model.authenticationFailureMessage
                            ?? model.lastError
                            ?? L("验证码验证失败，请检查后重试。"),
                        focus: oneTimeCodeField,
                        diagnostic: model.lastErrorDiagnostic
                    )
                    model.clearError()
                    updateSubmissionState(isSubmitting: false)
                }
                return
            }

            let result = await model.addSource(
                sourceID: sourceID,
                deviceName: deviceName,
                providerKind: .dsAudio,
                displayName: displayName,
                endpointText: endpointURL.absoluteString,
                account: account,
                password: password,
                oneTimeCode: normalizedCode
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .added:
                finishSuccessfully()
            case .verificationRequired:
                statusLabel.text = L("DSM 需要验证码，请在上方验证码栏输入后再次提交。")
                showError(
                    model.authenticationFailureMessage
                        ?? L("请输入 DSM 当前显示的六位验证码。"),
                    focus: oneTimeCodeField,
                    diagnostic: model.lastErrorDiagnostic ?? "one_time_code_required"
                )
                model.clearError()
                updateSubmissionState(isSubmitting: false)
            case let .failed(message):
                showError(message, diagnostic: model.lastErrorDiagnostic)
                model.clearError()
                updateSubmissionState(isSubmitting: false)
            }
        }
    }

    private var isSubmitting: Bool {
        submitButton.isEnabled == false
    }

    private func updateSubmissionState(isSubmitting: Bool) {
        submitButton.isEnabled = !isSubmitting
        navigationItem.leftBarButtonItem?.isEnabled = !isSubmitting
        if isSubmitting {
            activityIndicator.startAnimating()
            statusLabel.text = L("正在连接 DSM…")
        } else {
            activityIndicator.stopAnimating()
            if errorLabel.isHidden {
                statusLabel.text = L("验证码默认显示；如果 DSM 未启用二次验证可以留空。")
            }
        }
    }

    private func finishSuccessfully() {
        updateSubmissionState(isSubmitting: false)
        statusLabel.text = L("DS Audio 已添加")
        onAdded()
        dismiss(animated: true)
    }

    private func clearError() {
        errorLabel.text = nil
        errorLabel.isHidden = true
        diagnosticLabel.text = nil
        diagnosticLabel.isHidden = true
    }

    private func showError(
        _ message: String,
        focus field: UITextField? = nil,
        diagnostic: String? = nil
    ) {
        errorLabel.text = message
        errorLabel.isHidden = false
        if let diagnostic, !diagnostic.isEmpty {
            diagnosticLabel.text = L("诊断码：%@（可用于定位模拟器或 DSM 日志）", diagnostic)
            diagnosticLabel.isHidden = false
        } else {
            diagnosticLabel.text = nil
            diagnosticLabel.isHidden = true
        }
        if let field {
            field.becomeFirstResponder()
        }
    }
}

@MainActor
private final class DSAudioOneTimeCodeViewController: UIViewController {
    private let initialMessage: String?
    private let verify: (String) async -> Bool
    private let failureMessage: () -> String?
    private let onVerified: () -> Void
    private let onCancelled: () -> Void

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let codeField = UITextField()
    private let messageLabel = UILabel()
    private let errorLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var verifyTask: Task<Void, Never>?

    init(
        message: String?,
        verify: @escaping (String) async -> Bool,
        failureMessage: @escaping () -> String?,
        onVerified: @escaping () -> Void,
        onCancelled: @escaping () -> Void
    ) {
        initialMessage = message
        self.verify = verify
        self.failureMessage = failureMessage
        self.onVerified = onVerified
        self.onCancelled = onCancelled
        super.init(nibName: nil, bundle: nil)
        title = L("二次验证")
        restorationIdentifier = "onlineSources.dsaudio.oneTimeCode"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "onlineSources.dsaudio.oneTimeCode.sheet"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.leftBarButtonItem?.accessibilityIdentifier =
            "onlineSources.dsaudio.oneTimeCode.cancel"
        if #available(iOS 26.0, *) {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: L("验证"),
                style: .prominent,
                target: self,
                action: #selector(submit)
            )
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: L("验证"),
                image: nil,
                target: self,
                action: #selector(submit)
            )
        }
        navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "onlineSources.dsaudio.oneTimeCode.verify"

        configureLayout()
        if let initialMessage, !initialMessage.isEmpty {
            showError(initialMessage)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeField.becomeFirstResponder()
    }

    deinit {
        verifyTask?.cancel()
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.accessibilityIdentifier = "onlineSources.dsaudio.oneTimeCode.scroll"

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.medium
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.large,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.large,
            trailing: MusicFreeSpacingTokens.large
        )

        let titleLabel = UILabel()
        titleLabel.text = L("输入 DSM 验证码")
        titleLabel.font = MusicFreeUIFontTokens.preferred(.title2, weight: .bold)
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary

        let subtitleLabel = UILabel()
        subtitleLabel.text = L("请填写验证器应用中的当前六位验证码。验证失败时可以直接修改后再次提交。")
        subtitleLabel.font = MusicFreeUIFontTokens.secondary
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 0

        codeField.placeholder = L("六位验证码")
        codeField.borderStyle = .roundedRect
        codeField.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.autocorrectionType = .no
        codeField.clearButtonMode = .whileEditing
        codeField.accessibilityIdentifier = "onlineSources.dsaudio.oneTimeCode"
        codeField.heightAnchor.constraint(equalToConstant: 50).isActive = true

        messageLabel.text = L("验证码默认在添加 DS Audio 页面中填写；这里用于会话过期后的重新验证。")
        messageLabel.font = MusicFreeUIFontTokens.caption
        messageLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        messageLabel.numberOfLines = 0

        errorLabel.font = MusicFreeUIFontTokens.caption
        errorLabel.textColor = MusicFreeUIColorTokens.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "onlineSources.dsaudio.oneTimeCode.error"

        let actionRow = UIStackView(arrangedSubviews: [activityIndicator, makeVerifyButton()])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = MusicFreeSpacingTokens.small

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.addArrangedSubview(codeField)
        contentStack.addArrangedSubview(messageLabel)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(actionRow)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func makeVerifyButton() -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = L("验证并继续")
        configuration.image = UIImage(systemName: "checkmark.shield")
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        button.configuration = configuration
        button.accessibilityIdentifier = "onlineSources.dsaudio.oneTimeCode.submit"
        button.addAction(UIAction { [weak self] _ in
            self?.submit()
        }, for: .touchUpInside)
        return button
    }

    @objc private func cancel() {
        verifyTask?.cancel()
        onCancelled()
        dismiss(animated: true)
    }

    @objc private func submit() {
        guard verifyTask == nil else { return }
        let code = codeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !code.isEmpty else {
            showError(L("请输入验证码。"))
            codeField.becomeFirstResponder()
            return
        }

        view.endEditing(true)
        clearError()
        setSubmitting(true)
        verifyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let verified = await verify(code)
            guard !Task.isCancelled else { return }
            verifyTask = nil
            if verified {
                dismiss(animated: true) { [onVerified] in
                    onVerified()
                }
            } else {
                showError(
                    failureMessage()
                        ?? L("验证码不正确或已过期，请重新输入后再次提交。")
                )
                setSubmitting(false)
                codeField.becomeFirstResponder()
                codeField.selectAll(nil)
            }
        }
    }

    private func setSubmitting(_ submitting: Bool) {
        navigationItem.leftBarButtonItem?.isEnabled = !submitting
        navigationItem.rightBarButtonItem?.isEnabled = !submitting
        codeField.isEnabled = !submitting
        if submitting {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    private func clearError() {
        errorLabel.text = nil
        errorLabel.isHidden = true
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
    }
}

@MainActor
private func presentDSAudioSheet(
    _ controller: UIViewController,
    from presenter: UIViewController
) {
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 20
    }
    presenter.present(navigationController, animated: true)
}

@MainActor
private final class OnlineSourceCatalogViewController: UIViewController,
    UISearchBarDelegate,
    UISearchResultsUpdating,
    UICollectionViewDelegate
{
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-source-catalog"
    )

    /// The catalog is grouped so the directory listing reads as its own list
    /// instead of trailing the browse-mode entries inside one block.
    private enum CatalogSection: Hashable, CaseIterable {
        case categories
        case status
        case items
    }

    private enum CatalogRow: Hashable {
        case category(SourceCatalogBrowseMode)
        case googleDriveAuthorization
        case item(SourceObjectID)
        case feedback(String)
        case loading
        case loadingMore
        case loadMore
        case loadMoreFailure
        case state(String)
    }

    private static let virtualRootExternalID = "__online_source_root__"

    private let model: OnlineSourcesSceneModel
    private let sourceID: MediaSourceID
    private let parentID: SourceObjectID?
    private let directoryTitle: String
    private let browseMode: SourceCatalogBrowseMode
    private let collectionView: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        configuration.headerMode = .none
        configuration.footerMode = .none
        return UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
    }()
    private let searchController = UISearchController(searchResultsController: nil)
    private var collectionDataSource: UICollectionViewDiffableDataSource<
        CatalogSection,
        CatalogRow
    >!
    private var appliedRows: [CatalogRow] = []
    private var appliedRowSignatures: [CatalogRow: String] = [:]
    private var items: [SourceCatalogItem] = []
    private var nextPageToken: MediaSourceCursor?
    private var catalogSort = SourceCatalogSort.standard
    private var loadTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var auditionObservationTask: Task<Void, Never>?
    private var downloadObservationTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var submittedSearchQuery = ""
    private var isLoadingCatalog = false
    private var lastRequestedCatalogKey: String?
    private var searchTask: Task<Void, Never>?
    private var lastCatalogContentSignature: String?
    private var latestAuditionSnapshot = OnlineAuditionSnapshot.idle
    private var pendingAuditionItemID: SourceObjectID?
    private var lastPresentedAuditionFailureKey: String?
    private var auditionFailurePresentationTask: Task<Void, Never>?
    private var snapshotApplyInFlight = false
    private var pendingRender = false
    private var pendingRenderForce = false
    private var pendingLoadMore = false

    init(
        model: OnlineSourcesSceneModel,
        sourceID: MediaSourceID,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        title: String
    ) {
        self.model = model
        self.sourceID = sourceID
        self.parentID = parentID
        directoryTitle = title
        browseMode = mode
        super.init(nibName: nil, bundle: nil)
        self.title = title
        restorationIdentifier = "onlineSources.catalog"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = pageAccessibilityIdentifier
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        configureCollectionView()
        configureSearchBar()
        observeModel()
        render(force: true)
        beginLoadingCatalog()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.start()
            await model.refreshPersistedState()
            guard !Task.isCancelled else { return }
            render(force: true)
            ensureCatalogLoadIfNeeded()
        }
    }

    private var summary: OnlineSourceSummary? {
        model.snapshot.sources.first { $0.sourceID == sourceID }
    }

    private var isRoot: Bool { parentID == nil }

    private var pageAccessibilityIdentifier: String {
        if let parentID {
            return "onlineSources.detail.\(sourceID.rawValue).folder.\(parentID.externalID)"
        }
        return "onlineSources.detail.\(sourceID.rawValue)"
    }

    private var currentDirectoryItem: SourceCatalogItem {
        SourceCatalogItem(
            id: parentID ?? SourceObjectID(
                sourceID: sourceID,
                externalID: Self.virtualRootExternalID
            ),
            kind: .folder,
            displayName: directoryTitle
        )
    }

    private var currentImportSnapshot: OnlineSourceImportSnapshot? {
        if let snapshot = model.importSnapshots[currentDirectoryItem.id] {
            return snapshot
        }
        guard isRoot else { return nil }
        return model.importSnapshots.values.first {
            $0.rootItemID.sourceID == sourceID && $0.displayName == directoryTitle
        }
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "onlineSources.catalog.list"
        collectionView.delegate = self
        collectionView.register(
            OnlineSourceCatalogCollectionCell.self,
            forCellWithReuseIdentifier: OnlineSourceCatalogCollectionCell.reuseIdentifier
        )
        let refreshControl = UIRefreshControl()
        refreshControl.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).pullToRefresh"
        refreshControl.addTarget(self, action: #selector(refreshCatalog), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        collectionDataSource = UICollectionViewDiffableDataSource<CatalogSection, CatalogRow>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, row in
            guard let self,
                  let cell = collectionView.dequeueReusableCell(
                      withReuseIdentifier: OnlineSourceCatalogCollectionCell.reuseIdentifier,
                      for: indexPath
                  ) as? OnlineSourceCatalogCollectionCell
            else { return nil }
            configure(cell, for: row)
            return cell
        }

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureSearchBar() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = L("搜索当前目录")
        searchController.searchBar.returnKeyType = .search
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.accessibilityIdentifier =
            "onlineSources.detail.\(sourceID.rawValue).searchField"
        searchController.searchBar.searchTextField.accessibilityIdentifier =
            "onlineSources.detail.\(sourceID.rawValue).searchField"
        navigationItem.searchController = searchController
        // Keep the native search field in the navigation stack. The catalog
        // is a remote directory and search is a primary directory action;
        // hiding it on scroll makes the entry point disappear unpredictably.
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func observeModel() {
        observationTask?.cancel()
        auditionObservationTask?.cancel()
        downloadObservationTask?.cancel()

        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.model.serving.makeSnapshotStream()
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self.render()
                self.ensureCatalogLoadIfNeeded()
                await self.presentPendingAuthenticationIfNeeded()
            }
        }

        // The shared scene model also observes this stream, but that update is
        // scheduled independently from the catalog action. Keep a local copy
        // so the cell state cannot miss the short-lived preparing transition.
        auditionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.model.auditionServing.makeSnapshotStream()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self.latestAuditionSnapshot = snapshot
                // The stream yields its initial idle snapshot asynchronously.
                // It must not clear a request that was tapped before that
                // buffered value is consumed. Only an inactive snapshot for
                // the pending item (or an unowned idle state) may clear it.
                if snapshot.isActive {
                    self.pendingAuditionItemID = snapshot.itemID
                } else if self.pendingAuditionItemID == nil
                            || snapshot.itemID == self.pendingAuditionItemID {
                    self.pendingAuditionItemID = nil
                }
                self.render(force: true)
                if snapshot.phase == .failed {
                    self.scheduleAuditionFailurePresentation(for: snapshot)
                } else if !snapshot.isActive {
                    self.lastPresentedAuditionFailureKey = nil
                }
            }
        }

        downloadObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.model.downloadQueue.makeSnapshotStream()
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await Task.yield()
                self.render(force: true)
                self.updateDirectoryImportButton(for: self.summary)
            }
        }
    }

    private func presentPendingAuthenticationIfNeeded() async {
        guard model.authenticationChallengeSourceID == sourceID,
              viewIfLoaded?.window != nil,
              navigationController?.topViewController === self,
              presentedViewController == nil
        else { return }
        presentOneTimeCode()
    }

    private func presentOneTimeCode() {
        let controller = DSAudioOneTimeCodeViewController(
            message: model.authenticationFailureMessage,
            verify: { [weak self] code in
                guard let self else { return false }
                return await model.authenticateWithOneTimeCode(
                    sourceID: sourceID,
                    code: code
                )
            },
            failureMessage: { [weak self] in
                self?.model.authenticationFailureMessage
            },
            onVerified: { [weak self] in
                guard let self else { return }
                render(force: true)
                beginLoadingCatalog(query: submittedSearchQuery)
            },
            onCancelled: { [weak self] in
                self?.model.cancelAuthenticationChallenge()
            }
        )
        presentDSAudioSheet(controller, from: self)
    }

    private func beginLoadingCatalog(
        query: String? = nil,
        appending: Bool = false
    ) {
        guard let summary, canBrowse(summary) else {
            loadTask?.cancel()
            activeRequestID = nil
            items = []
            nextPageToken = nil
            isLoadingCatalog = false
            collectionView.refreshControl?.endRefreshing()
            render(force: true)
            return
        }

        if appending {
            guard nextPageToken != nil, !isLoadingCatalog else { return }
        }

        let normalizedQuery = (query ?? submittedSearchQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = catalogRequestKey(query: normalizedQuery)
        if !appending,
           isLoadingCatalog,
           lastRequestedCatalogKey == requestKey {
            return
        }

        loadTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        isLoadingCatalog = true
        let pageToken = appending ? nextPageToken : nil
        let preservedContentOffset = appending ? collectionView.contentOffset : nil

        if !appending {
            items = []
            nextPageToken = nil
            submittedSearchQuery = normalizedQuery
            lastRequestedCatalogKey = requestKey
        }
        Self.logger.info(
            "catalog request begin source=\(self.sourceID.rawValue) mode=\(self.browseMode.rawValue) parent=\(self.parentID?.externalID ?? "root") appending=\(appending) page=\(pageToken?.rawValue ?? "first") queryLength=\(normalizedQuery.count)"
        )
        render(force: true)

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let page: SourceCatalogPage?
            if normalizedQuery.isEmpty {
                page = await model.loadCatalogPage(
                    for: sourceID,
                    parentID: parentID,
                    mode: browseMode,
                    sort: catalogSort,
                    pageToken: pageToken
                )
            } else {
                page = await model.searchCatalogPage(
                    for: sourceID,
                    query: normalizedQuery,
                    parentID: parentID,
                    mode: browseMode,
                    sort: catalogSort,
                    pageToken: pageToken
                )
            }

            guard !Task.isCancelled, activeRequestID == requestID else { return }
            if let page {
                if appending {
                    let existingIDs = Set(items.map(\.id))
                    let newItems = page.items.filter { !existingIDs.contains($0.id) }
                    items.append(contentsOf: newItems)
                    if page.items.isEmpty
                        || newItems.isEmpty
                        || page.nextPageToken?.rawValue == pageToken?.rawValue {
                        nextPageToken = nil
                    } else {
                        nextPageToken = page.nextPageToken
                    }
                } else {
                    items = page.items
                    nextPageToken = page.nextPageToken
                }
            } else if !appending {
                nextPageToken = nil
            }

            isLoadingCatalog = false
            collectionView.refreshControl?.endRefreshing()
            Self.logger.info(
                "catalog request completed source=\(self.sourceID.rawValue) mode=\(self.browseMode.rawValue) appending=\(appending) items=\(page?.items.count ?? 0) next=\(page?.nextPageToken?.rawValue ?? "none")"
            )
            render(force: true)
            if let preservedContentOffset {
                view.layoutIfNeeded()
                collectionView.setContentOffset(preservedContentOffset, animated: false)
            }
            await presentPendingAuthenticationIfNeeded()
            if !appending {
                presentModelErrorIfNeeded()
            }
        }
    }

    /// A catalog can be opened before its source-level privacy or enablement
    /// gate is completed. The first request is intentionally skipped in that
    /// state; when the shared source snapshot changes, resume the initial load
    /// exactly once for the new runtime gate.
    private func ensureCatalogLoadIfNeeded() {
        guard let summary,
              canBrowse(summary),
              !isLoadingCatalog
        else { return }

        let requestKey = catalogRequestKey(query: submittedSearchQuery)
        guard lastRequestedCatalogKey != requestKey else { return }
        beginLoadingCatalog(query: submittedSearchQuery)
    }

    private func render(force: Bool = false) {
        guard isViewLoaded else { return }
        if snapshotApplyInFlight {
            pendingRender = true
            pendingRenderForce = pendingRenderForce || force
            return
        }
        title = directoryTitle
        view.accessibilityIdentifier = pageAccessibilityIdentifier
        updateDirectoryImportButton(for: summary)

        if summary?.capabilities.contains(.searching) == true {
            navigationItem.searchController = searchController
        } else {
            navigationItem.searchController = nil
        }

        let rows = catalogRows(for: summary)
        let contentSignature = catalogContentSignature(rows: rows)
        guard rows != appliedRows
            || contentSignature != lastCatalogContentSignature
        else {
            return
        }

        let currentIdentifiers = collectionDataSource.snapshot().itemIdentifiers
        var snapshot = NSDiffableDataSourceSnapshot<CatalogSection, CatalogRow>()
        for section in CatalogSection.allCases {
            let sectionRows = rows.filter { catalogSection(for: $0) == section }
            guard !sectionRows.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(sectionRows, toSection: section)
        }
        let reloadable = rows.filter {
            currentIdentifiers.contains($0)
                && appliedRowSignatures[$0] != catalogRowSignature($0)
        }
        if !reloadable.isEmpty {
            snapshot.reloadItems(reloadable)
        }
        let rowSignatures = Dictionary(uniqueKeysWithValues: rows.map {
            ($0, catalogRowSignature($0))
        })
        snapshotApplyInFlight = true
        appliedRows = rows
        appliedRowSignatures = rowSignatures
        lastCatalogContentSignature = contentSignature
        collectionDataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.finishSnapshotApply()
        }
    }

    private func finishSnapshotApply() {
        guard snapshotApplyInFlight else { return }
        snapshotApplyInFlight = false
        let shouldLoadMore = pendingLoadMore
        pendingLoadMore = false
        let needsRender = pendingRender || pendingRenderForce
        let force = pendingRenderForce
        pendingRender = false
        pendingRenderForce = false
        // UICollectionView can invoke willDisplay while the snapshot apply is
        // still on the call stack. Drain both pagination and rendering on the
        // next main-actor turn so a pagination update cannot nest another
        // apply or race the cells being installed by this snapshot.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            if shouldLoadMore {
                self.beginLoadingCatalog(appending: true)
            }
            if needsRender {
                self.render(force: force)
            }
        }
    }

    private func catalogSection(for row: CatalogRow) -> CatalogSection {
        switch row {
        case .category:
            return .categories
        case .googleDriveAuthorization, .feedback:
            return .status
        case .item, .loading, .loadingMore, .loadMore, .loadMoreFailure, .state:
            return .items
        }
    }

    private func catalogRows(for summary: OnlineSourceSummary?) -> [CatalogRow] {
        guard let summary else { return [.state("missingSource")] }
        guard canBrowse(summary) else { return [.state("sourceUnavailable")] }

        var rows = [CatalogRow]()
        if isRoot,
           browseMode == .folders,
           summary.providerKind == .dsAudio {
            // The folder listing is its own section below, so the folder mode
            // does not need a row that would only ever mark itself as current.
            rows.append(contentsOf: [
                .category(.albums),
                .category(.artists),
                .category(.allMusic),
            ])
        }
        if isRoot, summary.providerKind == .googleDrive {
            rows.append(.googleDriveAuthorization)
        }
        if let feedbackMessage = model.feedbackMessage,
           model.feedbackSourceID == sourceID {
            rows.append(.feedback(feedbackMessage))
        }

        if items.isEmpty {
            if isLoadingCatalog {
                rows.append(.loading)
            } else if currentCatalogFailureMessage != nil {
                rows.append(.state("catalogFailure"))
            } else {
                rows.append(.state("catalogEmpty"))
            }
            return rows
        }

        rows.append(contentsOf: items.map { .item($0.id) })
        if nextPageToken != nil {
            if isLoadingCatalog {
                rows.append(.loadingMore)
            } else if currentCatalogFailureMessage != nil {
                rows.append(.loadMoreFailure)
            } else {
                rows.append(.loadMore)
            }
        }
        return rows
    }

    private func catalogContentSignature(rows: [CatalogRow]) -> String {
        let rowSignature = rows.map(catalogRowSignature).joined(separator: "#")
        return [
            rowSignature,
            String(describing: self.summary),
            submittedSearchQuery,
            "sort:\(catalogSort.key.rawValue):\(catalogSort.direction.rawValue)",
            nextPageToken?.rawValue ?? "none",
        ].joined(separator: "::")
    }

    private func catalogRowSignature(_ row: CatalogRow) -> String {
        switch row {
        case let .category(mode): return "category:\(mode.rawValue)"
        case .googleDriveAuthorization: return "googleDriveAuthorization"
        case let .item(itemID):
            let item = items.first { $0.id == itemID }
            let download = model.downloadSnapshots[itemID]
            return [
                "item",
                itemID.externalID,
                item.map { catalogItemTitle($0) } ?? "",
                String(describing: item?.kind),
                String(latestAuditionSnapshot.isActive && latestAuditionSnapshot.itemID == itemID),
                String(pendingAuditionItemID == itemID),
                String(describing: download?.phase),
                download?.failureReason ?? "",
            ].joined(separator: "|")
        case let .feedback(message): return "feedback:\(message)"
        case .loading: return "loading"
        case .loadingMore: return "loadingMore"
        case .loadMore: return "loadMore"
        case .loadMoreFailure: return "loadMoreFailure:\(currentCatalogFailureMessage ?? "")"
        case let .state(key): return "state:\(key):\(currentCatalogFailureMessage ?? "")"
        }
    }

    private func configure(_ cell: OnlineSourceCatalogCollectionCell, for row: CatalogRow) {
        switch row {
        case let .category(mode):
            cell.configure(
                title: browseModeTitle(mode),
                subtitle: browseModeSubtitle(mode),
                systemImage: browseModeSymbol(mode),
                tintColor: MusicFreeUIColorTokens.accent,
                showsDisclosureIndicator: true
            )
            cell.accessibilityIdentifier =
                "onlineSources.detail.\(sourceID.rawValue).category.\(mode.rawValue)"
        case .googleDriveAuthorization:
            cell.configure(
                title: L("Google Drive 授权"),
                subtitle: L("授权后浏览云端目录并导入媒体库"),
                systemImage: "person.badge.key",
                tintColor: MusicFreeUIColorTokens.accent,
                trailingViews: [makeCatalogActionButton(
                    systemImage: "person.badge.key",
                    label: L("重新授权"),
                    identifier: "onlineSources.source.\(sourceID.rawValue).googleDrive.authorize",
                    action: { [weak self] in
                        self?.authorizeGoogleDrive()
                    }
                )]
            )
            cell.accessibilityIdentifier =
                "onlineSources.source.\(sourceID.rawValue).googleDrive.authorization"
        case let .item(itemID):
            guard let item = items.first(where: { $0.id == itemID }), let summary else {
                cell.configure(title: L("目录项"), systemImage: "questionmark")
                return
            }
            let title = catalogItemTitle(item)
            if item.kind.isContainer {
                cell.configure(
                    title: title,
                    subtitle: catalogKindTitle(item.kind),
                    systemImage: catalogKindSymbol(item.kind),
                    tintColor: MusicFreeUIColorTokens.accent,
                    showsDisclosureIndicator: true
                )
                cell.accessibilityIdentifier = itemAccessibilityID(item, action: "open")
            } else {
                cell.configure(
                    title: title,
                    subtitle: metadataLine(item),
                    systemImage: "music.note",
                    tintColor: MusicFreeUIColorTokens.accent,
                    trailingView: makeCatalogActionsView(item, summary: summary)
                )
                cell.accessibilityIdentifier = itemAccessibilityID(item, action: "row")
            }
        case let .feedback(message):
            cell.configure(
                title: message,
                subtitle: L("在线操作反馈"),
                systemImage: "checkmark.circle.fill",
                tintColor: MusicFreeUIColorTokens.positive
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).feedback"
        case .loading:
            cell.configure(
                title: L("正在加载目录"),
                subtitle: nil,
                systemImage: "ellipsis.circle",
                tintColor: MusicFreeUIColorTokens.foregroundSecondary,
                trailingView: makeActivityIndicator()
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).loading"
        case .loadingMore:
            cell.configure(
                title: L("正在加载更多"),
                subtitle: nil,
                systemImage: "ellipsis.circle",
                tintColor: MusicFreeUIColorTokens.foregroundSecondary,
                trailingView: makeActivityIndicator()
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).loadingMore"
        case .loadMore:
            cell.configure(
                title: L("加载更多"),
                subtitle: L("继续浏览目录"),
                systemImage: "chevron.down",
                tintColor: MusicFreeUIColorTokens.accent,
                trailingViews: [makeCatalogActionButton(
                    systemImage: "chevron.down",
                    label: L("加载更多"),
                    identifier: "onlineSources.detail.\(sourceID.rawValue).loadMore",
                    action: { [weak self] in
                        self?.beginLoadingCatalog(appending: true)
                    }
                )]
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).loadMore"
        case .loadMoreFailure:
            cell.configure(
                title: L("加载更多失败"),
                subtitle: currentCatalogFailureMessage ?? L("DSM 返回目录失败"),
                systemImage: "exclamationmark.triangle",
                tintColor: MusicFreeUIColorTokens.destructive,
                trailingViews: [makeCatalogActionButton(
                    systemImage: "arrow.clockwise",
                    label: L("重试加载更多"),
                    identifier: "onlineSources.detail.\(sourceID.rawValue).loadMore.retry",
                    action: { [weak self] in
                        self?.beginLoadingCatalog(appending: true)
                    }
                )]
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).loadMore.error"
        case let .state(key):
            let state = catalogState(key)
            let retryButton: [UIView] = key == "catalogFailure"
                ? [makeCatalogActionButton(
                    systemImage: "arrow.clockwise",
                    label: L("重试"),
                    identifier: "onlineSources.detail.\(sourceID.rawValue).catalog.retry",
                    action: { [weak self] in
                        self?.beginLoadingCatalog(query: self?.submittedSearchQuery)
                    }
                )]
                : []
            cell.configure(
                title: state.title,
                subtitle: state.message,
                systemImage: state.systemImage,
                tintColor: MusicFreeUIColorTokens.foregroundSecondary,
                trailingViews: retryButton
            )
            cell.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).\(key)"
        }
    }

    private func catalogState(_ key: String) -> (title: String, message: String, systemImage: String) {
        switch key {
        case "missingSource":
            return (L("来源不存在"), L("此来源已从设置中移除。"), "questionmark.folder")
        case "sourceUnavailable":
            return (L("来源当前不可用"), L("请在设置中同意协议并启用来源。"), "pause.circle")
        case "catalogFailure":
            return (L("目录加载失败"), currentCatalogFailureMessage ?? L("DSM 返回目录失败"), "exclamationmark.triangle")
        default:
            return (L("目录为空"), L("下拉刷新获取最新目录。"), "music.note")
        }
    }

    private func makeActivityIndicator() -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return indicator
    }

    private func makeCatalogActionButton(
        systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> OnlineSourceCatalogActionButton {
        let button = OnlineSourceCatalogActionButton(frame: .zero)
        configureCatalogActionButton(
            button,
            systemImage: systemImage,
            label: label,
            identifier: identifier
        )
        button.setActivationHandler(action)
        return button
    }

    private func configureCatalogActionButton(
        _ button: OnlineSourceCatalogActionButton,
        systemImage: String,
        label: String,
        identifier: String
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = MusicFreeUIColorTokens.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: 6,
            bottom: 6,
            trailing: 6
        )
        button.configuration = configuration
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
    }

    private func makeCatalogAuditionButton(
        _ item: SourceCatalogItem
    ) -> OnlineSourceCatalogActionButton {
        let isActive = isAuditionActive(for: item.id)
        let isFailed = !isActive
            && latestAuditionSnapshot.phase == .failed
            && latestAuditionSnapshot.itemID == item.id
        let button = makeCatalogActionButton(
            systemImage: isActive
                ? "stop.fill"
                : isFailed ? "exclamationmark.triangle" : "play.fill",
            label: isActive
                ? L("停止试听")
                : isFailed ? L("试听失败，重试") : L("试听"),
            identifier: itemAccessibilityID(
                item,
                action: isActive
                    ? "stopAudition"
                    : isFailed ? "retryAudition" : "audition"
            )
        ) { }
        button.setActivationHandler { [weak self, weak button] in
            guard let self else { return }
            let wasActive = self.isAuditionActive(for: item.id)
            Self.logger.info(
                "audition button activated source=\(self.sourceID.rawValue) item=\(item.id.externalID)"
            )
            // A retry of the same failed request must be allowed to present a
            // fresh error. The snapshot can keep the same failure identity
            // across attempts, so clear the presentation guard at activation.
            lastPresentedAuditionFailureKey = nil
            if wasActive {
                pendingAuditionItemID = nil
                latestAuditionSnapshot = OnlineAuditionSnapshot(
                    phase: .stopped,
                    sourceID: sourceID,
                    itemID: item.id,
                    displayName: catalogItemTitle(item),
                    duration: item.duration
                )
                if let button {
                    configureCatalogActionButton(
                        button,
                        systemImage: "play.fill",
                        label: L("试听"),
                        identifier: itemAccessibilityID(item, action: "audition")
                    )
                }
                scheduleCatalogRender()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await model.stopAudition()
                    latestAuditionSnapshot = model.auditionSnapshot
                    Self.logger.info(
                        "audition stop completed source=\(self.sourceID.rawValue) item=\(item.id.externalID) phase=\(self.latestAuditionSnapshot.phase.rawValue)"
                    )
                    scheduleCatalogRender()
                    presentModelErrorIfNeeded()
                }
            } else {
                pendingAuditionItemID = item.id
                latestAuditionSnapshot = OnlineAuditionSnapshot(
                    phase: .preparing,
                    sourceID: sourceID,
                    itemID: item.id,
                    displayName: catalogItemTitle(item),
                    duration: item.duration
                )
                if let button {
                    configureCatalogActionButton(
                        button,
                        systemImage: "stop.fill",
                        label: L("停止试听"),
                        identifier: itemAccessibilityID(item, action: "stopAudition")
                    )
                }
                scheduleCatalogRender()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await model.startAudition(sourceID: sourceID, items: items, startingItemID: item.id)
                    pendingAuditionItemID = nil
                    latestAuditionSnapshot = model.auditionSnapshot
                    Self.logger.info(
                        "audition action completed source=\(self.sourceID.rawValue) item=\(item.id.externalID) phase=\(self.latestAuditionSnapshot.phase.rawValue) error=\(self.latestAuditionSnapshot.failureReason ?? "none")"
                    )
                    scheduleCatalogRender()
                    presentModelErrorIfNeeded()
                }
            }
        }
        return button
    }

    private func isAuditionActive(for itemID: SourceObjectID) -> Bool {
        (latestAuditionSnapshot.isActive && latestAuditionSnapshot.itemID == itemID)
            || pendingAuditionItemID == itemID
    }

    private func scheduleCatalogRender(force: Bool = false) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            render(force: force)
        }
    }

    private func scheduleAuditionFailurePresentation(
        for snapshot: OnlineAuditionSnapshot
    ) {
        let failureKey = [
            snapshot.sourceID?.rawValue ?? "unknown",
            snapshot.itemID?.externalID ?? "unknown",
            snapshot.failureReason ?? "online_audition_failed",
        ].joined(separator: "|")
        guard lastPresentedAuditionFailureKey != failureKey else { return }

        auditionFailurePresentationTask?.cancel()
        auditionFailurePresentationTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                guard !Task.isCancelled, let self else { return }
                if self.navigationController?.topViewController === self,
                   self.presentedViewController == nil {
                    self.lastPresentedAuditionFailureKey = failureKey
                    self.presentMessage(
                        title: L("试听失败"),
                        message: snapshot.failureReason ?? L("在线音频暂时无法播放，请重试。")
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func makeCatalogActionsView(
        _ item: SourceCatalogItem,
        summary: OnlineSourceSummary
    ) -> UIView? {
        var actionViews = [UIView]()
        if item.isPlayable, summary.capabilities.contains(.onlinePlayback) {
            actionViews.append(makeCatalogAuditionButton(item))
        }
        if item.isDownloadable, summary.capabilities.contains(.downloading) {
            actionViews.append(makeCatalogDownloadAccessory(item))
        }

        // Keep the controls together as one fixed-width trailing view. The
        // collection cell owns this view directly so a download-state update
        // cannot make UIKit recalculate separate accessory regions and clip a
        // button under the cell edge.
        guard !actionViews.isEmpty else { return nil }

        let horizontalPadding = OnlineSourceCatalogLayout.actionHorizontalPadding
        let buttonDimension = OnlineSourceCatalogLayout.actionButtonDimension
        let container = OnlineSourceCatalogActionContainer(
            actionViews: actionViews,
            buttonDimension: buttonDimension,
            horizontalPadding: horizontalPadding
        )
        return container
    }

    private func makeCatalogDownloadAccessory(_ item: SourceCatalogItem) -> UIView {
        switch model.downloadSnapshots[item.id]?.phase {
        case .downloading, .importing:
            // A custom accessory already has to share the trailing space with
            // the audition button. Combining a spinner and a 44pt button in
            // a second accessory overflows the list-cell trailing margin and
            // clips the cancel affordance on narrow phones. The active row is
            // represented by one fixed-size cancel control; its accessibility
            // value retains the in-progress state for VoiceOver and UI tests.
            let button = makeCatalogActionButton(
                systemImage: "xmark",
                label: L("取消下载"),
                identifier: itemAccessibilityID(item, action: "cancelDownload")
            ) { [weak self] in
                guard let self else { return }
                Task { await model.cancelDownload(item.id) }
            }
            button.accessibilityValue = L("正在下载")
            return button
        case .failed, .cancelled:
            let button = makeCatalogActionButton(
                systemImage: "arrow.clockwise",
                label: L("重试下载"),
                identifier: itemAccessibilityID(item, action: "retryDownload")
            ) { }
            button.setActivationHandler { [weak self, weak button] in
                guard let self, let button else { return }
                configureCatalogActionButton(
                    button,
                    systemImage: "xmark",
                    label: L("取消下载"),
                    identifier: itemAccessibilityID(item, action: "cancelDownload")
                )
                startDownload(item)
            }
            return button
        case .completed, .alreadyImported:
            let status = makeStatusImage(
                systemImage: "checkmark.circle.fill",
                color: MusicFreeUIColorTokens.accent,
                identifier: itemAccessibilityID(
                    item,
                    action: model.downloadSnapshots[item.id]?.phase == .completed
                        ? "completed" : "alreadyImported"
                )
            )
            status.accessibilityLabel = L("已导入")
            return status
        case .skipped:
            return makeStatusImage(
                systemImage: "forward.end.circle",
                color: MusicFreeUIColorTokens.foregroundSecondary,
                identifier: itemAccessibilityID(item, action: "skipped")
            )
        case nil:
            let button = makeCatalogActionButton(
                systemImage: "arrow.down.circle",
                label: L("下载并导入"),
                identifier: itemAccessibilityID(item, action: "downloadAndImport")
            ) { }
            button.setActivationHandler { [weak self, weak button] in
                guard let self, let button else { return }
                configureCatalogActionButton(
                    button,
                    systemImage: "xmark",
                    label: L("取消下载"),
                    identifier: itemAccessibilityID(item, action: "cancelDownload")
                )
                startDownload(item)
            }
            return button
        }
    }

    private func startDownload(_ item: SourceCatalogItem) {
        model.startDownload(
            sourceID: sourceID,
            itemID: item.id,
            displayName: item.displayName,
            metadataHint: MediaImportMetadataHint(
                displayName: item.displayName,
                title: item.title,
                artist: item.artist,
                album: item.album,
                duration: item.duration
            )
        )
        scheduleCatalogRender(force: true)
    }

    private func pushCatalog(mode: SourceCatalogBrowseMode, parentID: SourceObjectID?, title: String) {
        navigationController?.pushViewController(
            OnlineSourceCatalogViewController(
                model: model,
                sourceID: sourceID,
                parentID: parentID,
                mode: mode,
                title: title
            ),
            animated: true
        )
    }

    private func childBrowseMode(for item: SourceCatalogItem) -> SourceCatalogBrowseMode {
        switch item.kind {
        case .album: return .albums
        case .artist: return .artists
        case .folder, .track, .audioFile, .unknown: return .folders
        }
    }

    private func browseModeTitle(_ mode: SourceCatalogBrowseMode) -> String {
        switch mode {
        case .folders: return L("文件夹")
        case .albums: return L("专辑")
        case .artists: return L("艺人")
        case .allMusic: return L("所有音乐")
        }
    }

    private func browseModeSubtitle(_ mode: SourceCatalogBrowseMode) -> String {
        switch mode {
        case .folders: return L("按文件夹浏览")
        case .albums: return L("按专辑浏览")
        case .artists: return L("按艺人浏览")
        case .allMusic: return L("浏览全部音乐")
        }
    }

    private func browseModeSymbol(_ mode: SourceCatalogBrowseMode) -> String {
        switch mode {
        case .folders: return "folder.fill"
        case .albums: return "square.stack.3d.up.fill"
        case .artists: return "person.2.fill"
        case .allMusic: return "music.note.list"
        }
    }

    private func catalogKindTitle(_ kind: SourceCatalogItemKind) -> String {
        switch kind {
        case .folder: return L("文件夹")
        case .album: return L("专辑")
        case .artist: return L("艺人")
        case .track, .audioFile, .unknown: return L("音频")
        }
    }

    private func catalogKindSymbol(_ kind: SourceCatalogItemKind) -> String {
        switch kind {
        case .folder: return "folder.fill"
        case .album: return "square.stack.3d.up.fill"
        case .artist: return "person.2.fill"
        case .track, .audioFile, .unknown: return "music.note"
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // The catalog spans several sections, so the row has to be resolved
        // through the data source rather than by a flat index.
        guard let row = collectionDataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        switch row {
        case let .category(mode):
            guard mode != browseMode else { return }
            pushCatalog(mode: mode, parentID: nil, title: browseModeTitle(mode))
        case let .item(itemID):
            guard let item = items.first(where: { $0.id == itemID }), item.kind.isContainer else { return }
            pushCatalog(
                mode: childBrowseMode(for: item),
                parentID: item.id,
                title: catalogItemTitle(item)
            )
        case .loadMore, .loadMoreFailure:
            beginLoadingCatalog(appending: true)
        case .state("catalogFailure"):
            beginLoadingCatalog(query: submittedSearchQuery)
        case .googleDriveAuthorization, .feedback, .loading, .loadingMore, .state:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard nextPageToken != nil,
              !isLoadingCatalog,
              appliedRows.count > 0
        else { return }
        if snapshotApplyInFlight {
            pendingLoadMore = true
            return
        }
        let visibleRowsPerScreen = max(1, Int(ceil(collectionView.bounds.height / 58)))
        let threshold = max(12, visibleRowsPerScreen * 2)
        // `indexPath.item` restarts at zero in every section, so measure the
        // distance to the end of the catalog on the flat row list.
        guard let row = collectionDataSource.itemIdentifier(for: indexPath),
              let flatIndex = appliedRows.firstIndex(of: row),
              flatIndex >= max(0, appliedRows.count - threshold)
        else { return }
        beginLoadingCatalog(appending: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchTask?.cancel()
        searchBar.resignFirstResponder()
        beginLoadingCatalog(query: searchBar.text ?? "")
    }

    func searchBarCancelButtonClicked(_: UISearchBar) {
        searchTask?.cancel()
        guard !submittedSearchQuery.isEmpty else { return }
        beginLoadingCatalog(query: "")
    }

    func updateSearchResults(for searchController: UISearchController) {
        // Catalog search is a remote operation. Wait for the native keyboard
        // Search action instead of issuing one request per typed character;
        // this also prevents an older query from racing the submitted one.
        searchTask?.cancel()
        searchTask = nil
    }

    deinit {
        loadTask?.cancel()
        observationTask?.cancel()
        auditionObservationTask?.cancel()
        auditionFailurePresentationTask?.cancel()
        downloadObservationTask?.cancel()
        searchTask?.cancel()
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        collectionView
    }

    @objc private func refreshCatalog() {
        beginLoadingCatalog(query: submittedSearchQuery)
    }

    #if false
    private func legacyRender(force: Bool = false) {
        guard isViewLoaded else { return }
        // Keep the navigation title aligned with the directory represented by
        // this controller. The source summary is stable across the whole
        // navigation stack, while `directoryTitle` changes when entering a
        // child folder.
        title = directoryTitle
        view.accessibilityIdentifier = pageAccessibilityIdentifier
        updateDirectoryImportButton(for: summary)

        let staticSignature = staticPresentationSignature
        if staticSignature != lastStaticRenderSignature {
            lastStaticRenderSignature = staticSignature
            renderStaticContent()
        }

        let dynamicSignature = dynamicPresentationSignature
        if force || dynamicSignature != lastDynamicRenderSignature {
            lastDynamicRenderSignature = dynamicSignature
            renderDynamicContent()
        }

        if let summary,
           canBrowse(summary),
           !isLoadingCatalog,
           lastRequestedCatalogKey != catalogRequestKey(query: submittedSearchQuery) {
            Task { @MainActor [weak self] in
                self?.beginLoadingCatalog()
            }
        }
    }

    private func renderStaticContent() {
        clearArrangedSubviews(in: staticContentStack)
        guard let summary else {
            clearArrangedSubviews(in: dynamicContentStack)
            staticContentStack.addArrangedSubview(makeStateView(
                title: L("来源不存在"),
                message: L("此来源已从设置中移除。"),
                systemImage: "questionmark.folder"
            ))
            return
        }

        staticContentStack.addArrangedSubview(makeSourceOverview(summary))
        if let feedbackMessage = model.feedbackMessage,
           model.feedbackSourceID == sourceID {
            staticContentStack.addArrangedSubview(makeFeedbackBanner(feedbackMessage))
        }
        staticContentStack.addArrangedSubview(makeSpacer(height: MusicFreeSpacingTokens.large))
        staticContentStack.addArrangedSubview(makeBrowseHeader())
        staticContentStack.addArrangedSubview(makeSpacer(height: MusicFreeSpacingTokens.medium))
        staticContentStack.addArrangedSubview(makeDirectoryCard())
        if summary.capabilities.contains(.searching) {
            staticContentStack.addArrangedSubview(makeSpacer(height: MusicFreeSpacingTokens.medium))
            staticContentStack.addArrangedSubview(searchBar)
        }
    }

    private func renderDynamicContent() {
        catalogCountLabel.text = L("%d 项", items.count)
        guard let summary else {
            clearCatalogContent()
            return
        }

        let summarySignature = catalogSummarySignature(summary)
        let canAppend = isAppendingCatalogPage
            && renderedCatalogSummarySignature == summarySignature
            && !renderedCatalogItemIDs.isEmpty
            && items.count >= renderedCatalogItemIDs.count
            && Array(items.prefix(renderedCatalogItemIDs.count).map(\.id))
                == renderedCatalogItemIDs

        if canAppend {
            appendCatalogRows(for: summary)
            updateCatalogFooter()
            return
        }

        renderedCatalogSummarySignature = summarySignature
        renderedCatalogItemIDs = []
        catalogControlsByItemID.removeAll(keepingCapacity: true)
        catalogControlSignatures.removeAll(keepingCapacity: true)
        clearArrangedSubviews(in: dynamicContentStack)
        clearArrangedSubviews(in: catalogItemsStack)
        clearArrangedSubviews(in: catalogFooterStack)

        guard canBrowse(summary) else {
            dynamicContentStack.addArrangedSubview(makeCatalogStateContent(
                title: L("来源当前不可用"),
                message: L("请先同意来源协议并启用来源。"),
                systemImage: "pause.circle"
            ))
            return
        }

        if items.isEmpty {
            if isLoadingCatalog {
                dynamicContentStack.addArrangedSubview(makeLoadingView())
            } else if currentCatalogFailureMessage != nil {
                dynamicContentStack.addArrangedSubview(makeCatalogStateContent(
                    title: L("目录加载失败"),
                    message: catalogFailureMessage,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: L("重试"),
                    action: { [weak self] in
                        self?.beginLoadingCatalog(query: self?.submittedSearchQuery)
                    }
                ))
            } else {
                dynamicContentStack.addArrangedSubview(makeCatalogStateContent(
                    title: L("目录为空"),
                    message: L("下拉刷新获取最新目录。"),
                    systemImage: "music.note"
                ))
            }
            return
        }

        dynamicContentStack.addArrangedSubview(makeSpacer(height: MusicFreeSpacingTokens.small))
        dynamicContentStack.addArrangedSubview(catalogItemsStack)
        dynamicContentStack.addArrangedSubview(catalogFooterStack)
        appendCatalogRows(for: summary)
        updateCatalogFooter()
    }

    private func clearCatalogContent() {
        renderedCatalogItemIDs = []
        renderedCatalogSummarySignature = nil
        catalogControlsByItemID.removeAll(keepingCapacity: true)
        catalogControlSignatures.removeAll(keepingCapacity: true)
        clearArrangedSubviews(in: dynamicContentStack)
        clearArrangedSubviews(in: catalogItemsStack)
        clearArrangedSubviews(in: catalogFooterStack)
    }

    private func appendCatalogRows(for summary: OnlineSourceSummary) {
        let startIndex = renderedCatalogItemIDs.count
        guard startIndex < items.count else { return }

        for index in startIndex..<items.count {
            if index > 0 {
                catalogItemsStack.addArrangedSubview(makeDivider(leadingInset: 48))
            }
            let item = items[index]
            catalogItemsStack.addArrangedSubview(item.kind.isContainer
                ? makeFolderRow(item)
                : makeAudioRow(item, summary: summary))
            renderedCatalogItemIDs.append(item.id)
        }
    }

    private func updateCatalogFooter() {
        clearArrangedSubviews(in: catalogFooterStack)
        guard nextPageToken != nil else { return }
        catalogFooterStack.addArrangedSubview(makeSpacer(height: MusicFreeSpacingTokens.medium))
        if isLoadingCatalog {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            let label = UILabel()
            label.text = L("正在加载更多")
            label.font = MusicFreeUIFontTokens.caption
            label.textColor = MusicFreeUIColorTokens.foregroundSecondary
            let loading = UIStackView(arrangedSubviews: [indicator, label])
            loading.axis = .horizontal
            loading.alignment = .center
            loading.spacing = MusicFreeSpacingTokens.small
            loading.isLayoutMarginsRelativeArrangement = true
            loading.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 8,
                leading: 16,
                bottom: 8,
                trailing: 16
            )
            catalogFooterStack.addArrangedSubview(loading)
        } else {
            if currentCatalogFailureMessage != nil {
                let errorLabel = UILabel()
                errorLabel.text = catalogFailureMessage
                errorLabel.font = MusicFreeUIFontTokens.caption
                errorLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
                errorLabel.numberOfLines = 0
                errorLabel.textAlignment = .center
                errorLabel.isAccessibilityElement = true
                errorLabel.accessibilityIdentifier =
                    "onlineSources.detail.\(sourceID.rawValue).loadMore.error"
                catalogFooterStack.addArrangedSubview(errorLabel)
            }
            catalogFooterStack.addArrangedSubview(
                makeLoadMoreControl(hasFailure: currentCatalogFailureMessage != nil)
            )
        }
    }

    private func catalogSummarySignature(_ summary: OnlineSourceSummary) -> String {
        [
            summary.sourceID.rawValue,
            summary.privacyPolicyVersion,
            String(summary.isRegistered),
            String(summary.isPrivacyAccepted),
            String(summary.isRuntimeEnabled),
            String(describing: summary.capabilities),
        ].joined(separator: "|")
    }

    private func makeCatalogStateContent(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> UIView {
        makeStateView(
            title: title,
            message: message,
            systemImage: systemImage,
            actionTitle: actionTitle,
            action: action
        )
    }

    private var catalogFailureMessage: String {
        currentCatalogFailureMessage
            ?? L("DSM 返回目录失败，下拉刷新或点击重试。")
    }

    #endif

    private var currentCatalogFailureMessage: String? {
        // A failed load-more request keeps its retry cursor in
        // `nextPageToken`; use that exact cursor so a stale pagination error
        // cannot appear as the first-page state after a refresh.
        let failedPageToken = items.isEmpty ? nil : nextPageToken
        return model.catalogFailureMessage(
            for: sourceID,
            parentID: parentID,
            mode: browseMode,
            sort: catalogSort,
            query: submittedSearchQuery,
            pageToken: failedPageToken
        )
    }

    #if false
    private func clearArrangedSubviews(in stack: UIStackView) {
        for arrangedSubview in stack.arrangedSubviews {
            stack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }

    private var staticPresentationSignature: String {
        [
            String(describing: summary),
            String(describing: model.feedbackMessage),
            String(describing: model.feedbackSourceID),
            String(isRoot),
            directoryTitle,
            String(summary?.capabilities.contains(.searching) ?? false)
        ].joined(separator: "#")
    }

    private var dynamicPresentationSignature: String {
        return [
            String(describing: summary),
            String(isLoadingCatalog),
            String(isAppendingCatalogPage),
            submittedSearchQuery,
            items.map(\.id.externalID).joined(separator: ","),
            items.map { "\($0.id.sourceID.rawValue):\($0.id.externalID):\(catalogItemTitle($0))" }
                .joined(separator: "|"),
            nextPageToken?.rawValue ?? "none",
            currentCatalogFailureMessage
                ?? "none"
        ].joined(separator: "#")
    }

    #endif

    private func catalogRequestKey(query: String) -> String {
        "\(sourceID.rawValue)|\(parentID?.externalID ?? "root")|\(browseMode.rawValue)|\(catalogSort.key.rawValue):\(catalogSort.direction.rawValue)|\(query)|\(model.authenticationRetryToken)|\(summary?.isRuntimeEnabled ?? false)"
    }

    private func canBrowse(_ summary: OnlineSourceSummary) -> Bool {
        summary.isRegistered
            && model.snapshot.isApplicationPrivacyAccepted
            && summary.isPrivacyAccepted
            && summary.isRuntimeEnabled
            && summary.capabilities.contains(.browsing)
    }


    #if false
    private func makeSourceOverview(_ summary: OnlineSourceSummary) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.backgroundColor = .clear

        let providerRow = UIStackView()
        providerRow.axis = .horizontal
        providerRow.alignment = .center
        providerRow.spacing = MusicFreeSpacingTokens.medium
        providerRow.isLayoutMarginsRelativeArrangement = true
        providerRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.xSmall,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.large
        )
        providerRow.addArrangedSubview(makeIconBadge(
            systemName: providerSymbol(summary.providerKind),
            backgroundColor: MusicFreeUIColorTokens.accentSoft
        ))
        let providerText = makeTextStack(
            title: providerTitle(summary.providerKind),
            subtitle: L("协议 %@", summary.privacyPolicyVersion)
        )
        providerRow.addArrangedSubview(providerText)
        providerRow.addArrangedSubview(makeFlexibleSpacer())
        providerRow.addArrangedSubview(makeStatusBadge(summary))
        providerRow.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).provider"
        stack.addArrangedSubview(providerRow)
        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(makeCapabilityRow(
            title: L("下载源"),
            subtitle: summary.capabilities.contains(.browsing)
                && summary.capabilities.contains(.downloading)
                ? L("浏览文件夹、搜索并下载后导入媒体库")
                : L("此来源未提供完整下载源能力"),
            isAvailable: summary.capabilities.contains(.browsing)
                && summary.capabilities.contains(.downloading),
            identifier: "onlineSources.detail.\(sourceID.rawValue).capabilities.download"
        ))
        stack.addArrangedSubview(makeDivider(leadingInset: MusicFreeSpacingTokens.large))
        stack.addArrangedSubview(makeCapabilityRow(
            title: L("播放源（试听）"),
            subtitle: summary.capabilities.contains(.onlinePlayback)
                ? L("通过 HTTP 或转码地址临时试听，不进入正式播放队列")
                : L("此来源不支持在线试听；下载后使用本地播放器播放"),
            isAvailable: summary.capabilities.contains(.onlinePlayback),
            identifier: "onlineSources.detail.\(sourceID.rawValue).capabilities.playback"
        ))

        if summary.providerKind == .googleDrive {
            let authorize = makePlainActionButton(
                title: L("重新授权"),
                systemImage: "person.badge.key",
                identifier: "onlineSources.source.\(sourceID.rawValue).googleDrive.authorize"
            ) { [weak self] in
                self?.authorizeGoogleDrive()
            }
            authorize.isEnabled = summary.isRuntimeEnabled
            let authContainer = UIStackView(arrangedSubviews: [authorize, makeFlexibleSpacer()])
            authContainer.axis = .horizontal
            authContainer.isLayoutMarginsRelativeArrangement = true
            authContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0,
                leading: MusicFreeSpacingTokens.large,
                bottom: MusicFreeSpacingTokens.small,
                trailing: MusicFreeSpacingTokens.large
            )
            stack.addArrangedSubview(authContainer)
        }
        return stack
    }

    private func makeCapabilityRow(
        title: String,
        subtitle: String,
        isAvailable: Bool,
        identifier: String
    ) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: isAvailable ? "checkmark.circle.fill" : "minus.circle"))
        icon.tintColor = isAvailable
            ? MusicFreeUIColorTokens.positive
            : MusicFreeUIColorTokens.foregroundSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        let row = UIStackView(arrangedSubviews: [
            icon,
            makeTextStack(title: title, subtitle: subtitle),
            makeFlexibleSpacer(),
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = MusicFreeSpacingTokens.medium
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.large
        )
        row.isAccessibilityElement = true
        row.accessibilityIdentifier = identifier
        row.accessibilityLabel = title
        row.accessibilityValue = isAvailable ? L("已支持") : L("未支持")
        return row
    }

    private func makeBrowseHeader() -> UIView {
        let title = UILabel()
        title.text = L("目录")
        title.font = MusicFreeUIFontTokens.preferred(.title3, weight: .bold)
        title.textColor = MusicFreeUIColorTokens.foregroundPrimary

        catalogCountLabel.font = MusicFreeUIFontTokens.caption
        catalogCountLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary

        let titleRow = UIStackView(arrangedSubviews: [title, makeFlexibleSpacer(), catalogCountLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline

        let subtitle = UILabel()
        subtitle.text = L("点击文件夹进入下一级")
        subtitle.font = MusicFreeUIFontTokens.caption
        subtitle.textColor = MusicFreeUIColorTokens.foregroundSecondary

        let stack = UIStackView(arrangedSubviews: [titleRow, subtitle])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        return stack
    }

    private func makeDirectoryCard() -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.alignment = .fill
        card.spacing = MusicFreeSpacingTokens.small
        card.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        card.layer.cornerCurve = .continuous
        card.layer.cornerRadius = 18
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.medium,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.medium
        )

        let directoryRow = UIStackView()
        directoryRow.axis = .horizontal
        directoryRow.alignment = .center
        directoryRow.spacing = MusicFreeSpacingTokens.medium
        directoryRow.addArrangedSubview(makeIconBadge(
            systemName: isRoot ? "externaldrive.fill.badge.icloud" : "chevron.left",
            backgroundColor: MusicFreeUIColorTokens.accentSoft
        ))
        directoryRow.addArrangedSubview(makeTextStack(
            title: isRoot ? L("根目录") : directoryTitle,
            subtitle: isRoot
                ? L("浏览此来源的文件夹和音频")
                : L("当前目录 · 使用右上角导入")
        ))
        directoryRow.addArrangedSubview(makeFlexibleSpacer())
        card.addArrangedSubview(directoryRow)
        return card
    }

    #endif

    private func updateDirectoryImportButton(for summary: OnlineSourceSummary?) {
        guard let summary else {
            updateNavigationBarItems(importButton: nil, includeSort: false)
            return
        }
        guard canBrowse(summary) else {
            updateNavigationBarItems(importButton: nil, includeSort: false)
            return
        }
        guard isImportAvailable(summary) else {
            updateNavigationBarItems(importButton: nil)
            return
        }

        let identifierPrefix = "onlineSources.detail.\(sourceID.rawValue).item.\(currentDirectoryItem.id.externalID)"
        let button: UIBarButtonItem
        // These are import-task lifecycle states, not selection states. Avoid
        // the circle/filled-circle pair used by multi-select rows.
        if let progress = currentImportSnapshot {
            switch progress.phase {
            case .discovering, .downloading, .importing:
                button = UIBarButtonItem(
                    image: UIImage(systemName: "xmark.circle"),
                    style: .plain,
                    target: self,
                    action: #selector(importCurrentDirectory)
                )
                button.accessibilityIdentifier = "\(identifierPrefix).cancelImport"
                button.accessibilityLabel = L("取消导入")
                button.accessibilityValue = L("进行中")
            case .completed:
                button = UIBarButtonItem(
                    image: UIImage(systemName: "checkmark.seal.fill"),
                    style: .plain,
                    target: self,
                    action: #selector(importCurrentDirectory)
                )
                button.accessibilityIdentifier = "\(identifierPrefix).downloadAndImportAll"
                button.accessibilityLabel = L("再次导入当前目录")
                button.accessibilityValue = L("已完成")
            case .cancelled, .failed:
                button = UIBarButtonItem(
                    image: UIImage(systemName: "arrow.clockwise.circle"),
                    style: .plain,
                    target: self,
                    action: #selector(importCurrentDirectory)
                )
                button.accessibilityIdentifier = "\(identifierPrefix).downloadAndImportAll"
                button.accessibilityLabel = L("重试导入当前目录")
                button.accessibilityValue = L("可重试")
            }
        } else {
            button = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.down"),
                style: .plain,
                target: self,
                action: #selector(importCurrentDirectory)
            )
            button.accessibilityIdentifier = "\(identifierPrefix).downloadAndImportAll"
            button.accessibilityLabel = L("导入当前目录")
            button.accessibilityValue = L("未开始")
        }
        button.accessibilityHint = L("开始独立下载任务；离开此页面后仍会继续执行")
        updateNavigationBarItems(importButton: button)
    }

    private func updateNavigationBarItems(
        importButton: UIBarButtonItem?,
        includeSort: Bool = true
    ) {
        var buttons = [UIBarButtonItem]()
        if includeSort {
            buttons.append(makeCatalogSortBarButtonItem())
        }
        if let importButton {
            buttons.append(importButton)
        }
        navigationItem.rightBarButtonItems = buttons.isEmpty ? nil : buttons
    }

    private func makeCatalogSortBarButtonItem() -> UIBarButtonItem {
        let button = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            style: .plain,
            target: nil,
            action: nil
        )
        button.menu = makeCatalogSortMenu()
        button.accessibilityIdentifier =
            "onlineSources.detail.\(sourceID.rawValue).sort"
        button.accessibilityLabel = L("排序方式")
        button.accessibilityValue = catalogSortTitle(catalogSort)
        return button
    }

    private func makeCatalogSortMenu() -> UIMenu {
        let actions = SourceCatalogSort.options(for: browseMode).map { option in
            UIAction(
                title: catalogSortTitle(option),
                state: option == catalogSort ? .on : .off
            ) { [weak self] _ in
                self?.selectCatalogSort(option)
            }
        }
        return UIMenu(
            title: L("排序方式"),
            image: UIImage(systemName: "arrow.up.arrow.down"),
            children: actions
        )
    }

    private func selectCatalogSort(_ sort: SourceCatalogSort) {
        guard sort != catalogSort else { return }
        catalogSort = sort
        lastRequestedCatalogKey = nil
        beginLoadingCatalog(query: submittedSearchQuery)
    }

    private func catalogSortTitle(_ sort: SourceCatalogSort) -> String {
        let direction = sort.direction == .ascending ? L("升序") : L("降序")
        switch sort.key {
        case .name:
            return L("名称 %@", direction)
        case .artist:
            return L("艺人 %@", direction)
        case .album:
            return L("专辑 %@", direction)
        case .year:
            return L("年份 %@", direction)
        }
    }

    @objc private func importCurrentDirectory() {
        guard let summary, isImportAvailable(summary) else { return }
        if let progress = currentImportSnapshot,
           [.discovering, .downloading, .importing].contains(progress.phase) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await model.cancelImport(progress.rootItemID)
                updateDirectoryImportButton(for: summary)
            }
            return
        }

        if isRoot {
            model.startImportFromRoot(sourceID: sourceID, displayName: summary.displayName)
        } else {
            model.startImport(sourceID: sourceID, item: currentDirectoryItem)
        }
        updateDirectoryImportButton(for: summary)
    }

    #if false
    private func makeLoadMoreControl(hasFailure: Bool) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = hasFailure ? L("加载更多失败，重试") : L("加载更多")
        configuration.image = UIImage(systemName: hasFailure ? "arrow.clockwise" : "chevron.down")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = MusicFreeUIColorTokens.accent
        button.configuration = configuration
        button.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).loadMore"
        button.isEnabled = !isLoadingCatalog
        button.addAction(UIAction { [weak self] _ in
            self?.beginLoadingCatalog(appending: true)
        }, for: .touchUpInside)
        return button
    }

    private func makeFolderRow(_ item: SourceCatalogItem) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = MusicFreeUIColorTokens.accent
        button.contentHorizontalAlignment = .fill
        button.accessibilityIdentifier = itemAccessibilityID(item, action: "open")
        button.accessibilityLabel = catalogItemTitle(item)
        button.accessibilityValue = item.kind == .album ? L("专辑") : L("文件夹")
        button.accessibilityHint = L("进入文件夹并浏览下一级内容")
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            navigationItem.backButtonDisplayMode = .minimal
            navigationController?.pushViewController(
                OnlineSourceCatalogViewController(
                    model: model,
                    sourceID: sourceID,
                    parentID: item.id,
                    title: catalogItemTitle(item)
                ),
                animated: true
            )
        }, for: .touchUpInside)

        let icon = UIImageView(image: UIImage(systemName: item.kind == .album ? "square.stack.3d.up.fill" : "folder.fill"))
        icon.tintColor = MusicFreeUIColorTokens.accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        let text = makeTextStack(
            title: catalogItemTitle(item),
            subtitle: item.kind == .album ? L("专辑") : L("文件夹")
        )
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        let row = UIStackView(arrangedSubviews: [icon, text, makeFlexibleSpacer(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = MusicFreeSpacingTokens.medium
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: MusicFreeSpacingTokens.medium),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -MusicFreeSpacingTokens.medium),
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: MusicFreeSpacingTokens.small),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
        return button
    }

    private func makeAudioRow(_ item: SourceCatalogItem, summary: OnlineSourceSummary) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = MusicFreeSpacingTokens.medium
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.medium,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.medium
        )

        let icon = UIImageView(image: UIImage(systemName: "music.note"))
        icon.tintColor = MusicFreeUIColorTokens.accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        row.addArrangedSubview(icon)
        row.addArrangedSubview(makeTextStack(
            title: catalogItemTitle(item),
            subtitle: metadataLine(item)
        ))
        row.addArrangedSubview(makeFlexibleSpacer())

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = MusicFreeSpacingTokens.small
        if item.isPlayable, summary.capabilities.contains(.onlinePlayback) {
            controls.addArrangedSubview(makeAuditionButton(item))
        }
        if item.isDownloadable, summary.capabilities.contains(.downloading) {
            controls.addArrangedSubview(makeDownloadControl(item))
        }
        if !controls.arrangedSubviews.isEmpty {
            catalogControlsByItemID[item.id] = controls
            catalogControlSignatures[item.id] = catalogControlSignature(item, summary: summary)
            row.addArrangedSubview(controls)
        }
        return row
    }

    private func refreshCatalogControls() {
        guard let summary else { return }
        for (itemID, controls) in catalogControlsByItemID {
            guard let item = items.first(where: { $0.id == itemID }) else { continue }
            let nextSignature = catalogControlSignature(item, summary: summary)
            guard catalogControlSignatures[itemID] != nextSignature else { continue }
            controls.arrangedSubviews.forEach { view in
                controls.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if item.isPlayable, summary.capabilities.contains(.onlinePlayback) {
                controls.addArrangedSubview(makeAuditionButton(item))
            }
            if item.isDownloadable, summary.capabilities.contains(.downloading) {
                controls.addArrangedSubview(makeDownloadControl(item))
            }
            catalogControlSignatures[itemID] = nextSignature
        }
    }

    private func catalogControlSignature(
        _ item: SourceCatalogItem,
        summary: OnlineSourceSummary
    ) -> String {
        let download = model.downloadSnapshots[item.id]
        return [
            String(item.isPlayable && summary.capabilities.contains(.onlinePlayback)),
            String(item.isDownloadable && summary.capabilities.contains(.downloading)),
            String(model.auditionSnapshot.isActive && model.auditionSnapshot.itemID == item.id),
            String(describing: download?.phase),
            download?.failureReason ?? ""
        ].joined(separator: "\u{001F}")
    }

    private func makeAuditionButton(_ item: SourceCatalogItem) -> UIButton {
        let isActive = model.auditionSnapshot.isActive && model.auditionSnapshot.itemID == item.id
        return makePlainActionButton(
            title: isActive ? L("停止") : L("试听"),
            systemImage: isActive ? "stop.fill" : "play.fill",
            identifier: itemAccessibilityID(item, action: isActive ? "stopAudition" : "audition")
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isActive {
                    await model.stopAudition()
                } else {
                    await model.startAudition(sourceID: sourceID, items: items, startingItemID: item.id)
                }
                refreshCatalogControls()
                presentModelErrorIfNeeded()
            }
        }
    }

    private func makeDownloadControl(_ item: SourceCatalogItem) -> UIView {
        switch model.downloadSnapshots[item.id]?.phase {
        case .downloading, .importing:
            let progress = UIActivityIndicatorView(style: .medium)
            progress.startAnimating()
            progress.isAccessibilityElement = true
            progress.accessibilityIdentifier = itemAccessibilityID(
                item,
                action: model.downloadSnapshots[item.id]?.phase == .downloading
                    ? "downloadProgress"
                    : "importProgress"
            )
            let cancel = makeSymbolButton(
                systemImage: "xmark",
                identifier: itemAccessibilityID(item, action: "cancelDownload")
            ) { [weak self] in
                guard let self else { return }
                Task { await model.cancelDownload(item.id) }
            }
            return UIStackView(arrangedSubviews: [progress, cancel])
        case .failed, .cancelled:
            return makeSymbolButton(
                systemImage: "arrow.clockwise",
                identifier: itemAccessibilityID(item, action: "retryDownload")
            ) { [weak self] in
                self?.startDownload(item)
            }
        case .completed, .alreadyImported:
            let status = makeStatusImage(
                systemImage: "checkmark.circle.fill",
                color: MusicFreeUIColorTokens.accent,
                identifier: itemAccessibilityID(
                    item,
                    action: model.downloadSnapshots[item.id]?.phase == .completed
                        ? "completed" : "alreadyImported"
                )
            )
            status.accessibilityLabel = L("已导入")
            return status
        case .skipped:
            return makeStatusImage(
                systemImage: "forward.end.circle",
                color: MusicFreeUIColorTokens.foregroundSecondary,
                identifier: itemAccessibilityID(item, action: "skipped")
            )
        case nil:
            return makePlainActionButton(
                title: L("导入"),
                systemImage: "arrow.down.circle",
                identifier: itemAccessibilityID(item, action: "downloadAndImport")
            ) { [weak self] in
                self?.legacyStartDownload(item)
            }
        }
    }

    private func legacyStartDownload(_ item: SourceCatalogItem) {
        model.startDownload(
            sourceID: sourceID,
            itemID: item.id,
            displayName: item.displayName,
            metadataHint: MediaImportMetadataHint(
                displayName: item.displayName,
                title: item.title,
                artist: item.artist,
                album: item.album,
                duration: item.duration
            )
        )
        refreshCatalogControls()
    }

    private func makeStatusBadge(_ summary: OnlineSourceSummary) -> UIView {
        let label = UILabel()
        label.text = statusTitle(summary)
        label.font = MusicFreeUIFontTokens.caption
        label.textColor = statusColor(summary)
        let stack = UIStackView(arrangedSubviews: [label])
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        stack.backgroundColor = statusColor(summary).withAlphaComponent(0.12)
        stack.layer.cornerCurve = .continuous
        stack.layer.cornerRadius = 12
        return stack
    }

    private func statusTitle(_ summary: OnlineSourceSummary) -> String {
        if summary.isRuntimeEnabled { return L("可用") }
        if !summary.isPrivacyAccepted { return L("待同意") }
        return L("已停用")
    }

    private func statusColor(_ summary: OnlineSourceSummary) -> UIColor {
        summary.isRuntimeEnabled ? MusicFreeUIColorTokens.positive : MusicFreeUIColorTokens.foregroundSecondary
    }

    private func makeIconBadge(systemName: String, backgroundColor: UIColor) -> UIView {
        let imageView = UIImageView(image: UIImage(systemName: systemName))
        imageView.tintColor = MusicFreeUIColorTokens.accent
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.backgroundColor = backgroundColor
        container.layer.cornerCurve = .continuous
        container.layer.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 36),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeTextStack(title: String, subtitle: String?) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = MusicFreeUIFontTokens.preferred(.body, weight: .semibold)
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 2
        let views: [UIView]
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = UILabel()
            subtitleLabel.text = subtitle
            subtitleLabel.font = MusicFreeUIFontTokens.caption
            subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
            subtitleLabel.numberOfLines = 2
            views = [titleLabel, subtitleLabel]
        } else {
            views = [titleLabel]
        }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func makeFeedbackBanner(_ message: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = MusicFreeUIColorTokens.positive
        let label = UILabel()
        label.text = message
        label.font = MusicFreeUIFontTokens.caption
        label.textColor = MusicFreeUIColorTokens.foregroundPrimary
        label.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [icon, label, makeFlexibleSpacer()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.large
        )
        stack.backgroundColor = MusicFreeUIColorTokens.positive.withAlphaComponent(0.10)
        stack.accessibilityIdentifier = "onlineSources.detail.\(sourceID.rawValue).feedback"
        return stack
    }

    private func makePlainActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        configuration.baseForegroundColor = MusicFreeUIColorTokens.accent
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.titleLabel?.font = MusicFreeUIFontTokens.caption
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makeSymbolButton(
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemImage), for: .normal)
        button.tintColor = MusicFreeUIColorTokens.accent
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        return button
    }

    #endif

    private func makeStatusImage(systemImage: String, color: UIColor, identifier: String) -> UIImageView {
        // A bare symbol view stretches to fill the trailing container, which made
        // the completed checkmark dwarf the action buttons next to it. Size the
        // symbol from text metrics and let it hug its intrinsic bounds instead.
        let image = UIImageView(
            image: UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    font: MusicFreeUIFontTokens.preferred(.body, weight: .regular)
                )
            )
        )
        image.tintColor = color
        image.contentMode = .center
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.setContentHuggingPriority(.required, for: .vertical)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        image.isAccessibilityElement = true
        image.accessibilityIdentifier = identifier
        return image
    }

    #if false
    private func makeLoadingView() -> UIView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        let label = UILabel()
        label.text = L("正在加载目录")
        label.font = MusicFreeUIFontTokens.secondary
        label.textColor = MusicFreeUIColorTokens.foregroundSecondary
        let stack = UIStackView(arrangedSubviews: [indicator, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 32, leading: 16, bottom: 32, trailing: 16)
        return stack
    }

    private func makeStateView(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> UIView {
        let image = UIImageView(image: UIImage(systemName: systemImage))
        image.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        image.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = MusicFreeUIFontTokens.sectionTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = MusicFreeUIFontTokens.caption
        messageLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        var arrangedSubviews: [UIView] = [image, titleLabel, messageLabel]
        if let actionTitle, let action {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = actionTitle
            configuration.baseBackgroundColor = MusicFreeUIColorTokens.accent
            configuration.baseForegroundColor = MusicFreeUIColorTokens.onAccent
            configuration.cornerStyle = .medium
            button.configuration = configuration
            button.accessibilityIdentifier =
                "onlineSources.detail.\(sourceID.rawValue).catalog.retry"
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            arrangedSubviews.append(button)
        }
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 16, bottom: 28, trailing: 16)
        return stack
    }

    private func makeDivider(leadingInset: CGFloat = 0) -> UIView {
        let container = UIView()
        let divider = UIView()
        divider.backgroundColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.35)
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return container
    }

    private func makeSpacer(height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func makeFlexibleSpacer() -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    #endif

    private func itemAccessibilityID(_ item: SourceCatalogItem, action: String) -> String {
        "onlineSources.detail.\(sourceID.rawValue).item.\(item.id.externalID).\(action)"
    }

    private func catalogItemTitle(_ item: SourceCatalogItem) -> String {
        // `displayName` is the source filename and must remain available for
        // download/import. Only use a separate title when it is genuinely
        // different from that filename; DSM commonly echoes the filename in
        // its `title` field for folder listings.
        let candidate: String = item.kind.isContainer
            ? item.displayName
            : meaningfulCatalogTitle(for: item) ?? catalogDisplayNameStem(for: item)
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "—", value != "-" else {
            switch item.kind {
            case .album: return L("未命名专辑")
            case .artist: return L("未命名艺人")
            case .folder: return L("未命名文件夹")
            case .track, .audioFile, .unknown: return L("未命名音频")
            }
        }
        return value
    }

    private func meaningfulCatalogTitle(for item: SourceCatalogItem) -> String? {
        guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              title != "—",
              title != "-"
        else { return nil }

        let titleName = URL(fileURLWithPath: title).lastPathComponent
        let titleStem = URL(fileURLWithPath: titleName)
            .deletingPathExtension()
            .lastPathComponent
        let displayName = URL(fileURLWithPath: item.displayName).lastPathComponent
        let displayStem = URL(fileURLWithPath: displayName)
            .deletingPathExtension()
            .lastPathComponent
        let normalizedTitle = titleStem.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDisplayStem = displayStem.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedTitle != normalizedDisplayName,
              normalizedTitle != normalizedDisplayStem
        else { return nil }
        return title
    }

    private func catalogDisplayNameStem(for item: SourceCatalogItem) -> String {
        let name = URL(fileURLWithPath: item.displayName).lastPathComponent
        let stem = URL(fileURLWithPath: name)
            .deletingPathExtension()
            .lastPathComponent
        return stem.isEmpty ? name : stem
    }

    private func metadataLine(_ item: SourceCatalogItem) -> String? {
        var values = [String]()
        if let artist = item.artist { values.append(artist) }
        if let album = item.album { values.append(album) }
        if let duration = item.duration {
            let seconds = max(0, duration.components.seconds)
            values.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func isImportAvailable(_ summary: OnlineSourceSummary) -> Bool {
        summary.isRegistered
            && summary.isPrivacyAccepted
            && summary.isRuntimeEnabled
            && summary.capabilities.contains(.browsing)
            && summary.capabilities.contains(.downloading)
    }

    #if false
    private func providerTitle(_ kind: OnlineProviderKind) -> String {
        switch kind {
        case .dsAudio: L("DS Audio")
        case .googleDrive: L("Google Drive")
        case .baiduPan: L("百度网盘")
        case .gateway: L("网关")
        }
    }

    private func providerSymbol(_ kind: OnlineProviderKind) -> String {
        switch kind {
        case .dsAudio: "waveform"
        case .googleDrive: "externaldrive"
        case .baiduPan: "cloud"
        case .gateway: "network"
        }
    }

    private func authorizeGoogleDrive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.authorizeGoogleDrive(for: sourceID)
            render(force: true)
            if model.lastError == nil {
                beginLoadingCatalog()
            }
            presentModelErrorIfNeeded()
        }
    }

    #endif

    private func presentModelErrorIfNeeded() {
        guard presentedViewController == nil, let message = model.lastError else { return }
        model.clearError()
        presentMessage(title: L("在线源操作失败"), message: message)
    }

    private func authorizeGoogleDrive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.authorizeGoogleDrive(for: sourceID)
            render(force: true)
            if model.lastError == nil {
                beginLoadingCatalog(query: submittedSearchQuery)
            }
            presentModelErrorIfNeeded()
        }
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }
}

private final class OnlineSourceCatalogCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "OnlineSourceCatalogCollectionCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let trailingContainer = UIView()
    private let disclosureView = UIImageView()
    private let rowStack = UIStackView()
    private var trailingWidthConstraint: NSLayoutConstraint!
    private var installedTrailingView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundConfiguration = .listGroupedCell()
        contentView.isUserInteractionEnabled = true
        trailingContainer.isUserInteractionEnabled = true
        // The trailing audition/download controls live inside this stack. A
        // disabled stack makes UIKit skip hit-testing for every descendant,
        // even though the buttons remain visible and individually enabled.
        rowStack.isUserInteractionEnabled = true

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])

        titleLabel.font = MusicFreeUIFontTokens.preferred(.body, weight: .semibold)
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 2
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = MusicFreeUIFontTokens.caption
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        trailingContainer.setContentHuggingPriority(.required, for: .horizontal)
        trailingContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingWidthConstraint = trailingContainer.widthAnchor.constraint(equalToConstant: 0)
        trailingWidthConstraint.isActive = true
        trailingContainer.heightAnchor.constraint(equalToConstant: 44).isActive = true
        trailingContainer.isHidden = true

        // A plain 44pt-tall symbol view stretched the chevron far beyond the
        // system disclosure indicator. Size it from the text metrics instead and
        // let it hug its intrinsic width.
        disclosureView.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(
                font: MusicFreeUIFontTokens.preferred(.subheadline, weight: .semibold)
            )
        )
        disclosureView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        disclosureView.contentMode = .center
        disclosureView.isAccessibilityElement = false
        disclosureView.isHidden = true
        disclosureView.setContentHuggingPriority(.required, for: .horizontal)
        disclosureView.setContentCompressionResistancePriority(.required, for: .horizontal)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = MusicFreeSpacingTokens.medium
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(iconView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(trailingContainer)
        rowStack.addArrangedSubview(disclosureView)
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: MusicFreeSpacingTokens.medium
            ),
            rowStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
            rowStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: MusicFreeSpacingTokens.small
            ),
            rowStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        installedTrailingView?.removeFromSuperview()
        installedTrailingView = nil
        trailingWidthConstraint.constant = 0
        trailingContainer.isHidden = true
        disclosureView.isHidden = true
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    func configure(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tintColor: UIColor = MusicFreeUIColorTokens.foregroundPrimary,
        trailingViews: [UIView] = [],
        trailingView: UIView? = nil,
        showsDisclosureIndicator: Bool = false
    ) {
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.tintColor = tintColor
        iconView.isHidden = systemImage == nil
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        disclosureView.isHidden = !showsDisclosureIndicator

        installedTrailingView?.removeFromSuperview()
        installedTrailingView = nil
        let customViews = trailingViews + (trailingView.map { [$0] } ?? [])
        guard !customViews.isEmpty else {
            trailingWidthConstraint.constant = 0
            trailingContainer.isHidden = true
            return
        }

        let installedView: UIView
        if customViews.count == 1 {
            installedView = customViews[0]
        } else {
            let stack = UIStackView(arrangedSubviews: customViews)
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.distribution = .fillEqually
            stack.spacing = 0
            installedView = stack
        }
        installedView.translatesAutoresizingMaskIntoConstraints = false
        installedView.isUserInteractionEnabled = true
        trailingContainer.addSubview(installedView)
        installedTrailingView = installedView

        let intrinsicSize = installedView.intrinsicContentSize
        let width = max(
            OnlineSourceCatalogLayout.actionButtonDimension,
            ceil(installedView.bounds.width > 0 ? installedView.bounds.width : intrinsicSize.width)
        )
        NSLayoutConstraint.activate([
            installedView.leadingAnchor.constraint(equalTo: trailingContainer.leadingAnchor),
            installedView.trailingAnchor.constraint(equalTo: trailingContainer.trailingAnchor),
            installedView.topAnchor.constraint(equalTo: trailingContainer.topAnchor),
            installedView.bottomAnchor.constraint(equalTo: trailingContainer.bottomAnchor),
        ])
        trailingWidthConstraint.constant = width
        trailingContainer.isHidden = false
    }
}

private enum OnlineSourceCatalogLayout {
    static let actionButtonDimension: CGFloat = 44
    static let actionHorizontalPadding: CGFloat = 4
}

@MainActor
private final class OnlineSourceCatalogActionButton: UIButton {
    private var activationHandler: (() -> Void)?

    override var intrinsicContentSize: CGSize {
        CGSize(width: 44, height: 44)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        accessibilityTraits = [.button]
    }

    func setActivationHandler(_ handler: @escaping () -> Void) {
        activationHandler = handler
        removeTarget(self, action: #selector(handleActivation), for: .touchUpInside)
        addTarget(self, action: #selector(handleActivation), for: .touchUpInside)
    }

    @objc private func handleActivation() {
        activationHandler?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

}

@MainActor
private final class OnlineSourceCatalogActionContainer: UIView {
    private let actionViews: [UIView]
    private let buttonDimension: CGFloat
    private let horizontalPadding: CGFloat

    init(actionViews: [UIView], buttonDimension: CGFloat, horizontalPadding: CGFloat) {
        self.actionViews = actionViews
        self.buttonDimension = buttonDimension
        self.horizontalPadding = horizontalPadding
        let width = CGFloat(max(1, actionViews.count)) * buttonDimension
            + horizontalPadding * 2
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: width, height: buttonDimension)))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        for (index, actionView) in actionViews.enumerated() {
            actionView.translatesAutoresizingMaskIntoConstraints = false
            actionView.isUserInteractionEnabled = true
            addSubview(actionView)

            NSLayoutConstraint.activate([
                actionView.widthAnchor.constraint(equalToConstant: buttonDimension),
                actionView.heightAnchor.constraint(equalToConstant: buttonDimension),
                actionView.topAnchor.constraint(equalTo: topAnchor),
            ])

            if index == 0 {
                actionView.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: horizontalPadding
                ).isActive = true
            } else {
                actionView.leadingAnchor.constraint(
                    equalTo: actionViews[index - 1].trailingAnchor
                ).isActive = true
            }

            if index == actionViews.count - 1 {
                actionView.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -horizontalPadding
                ).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: CGFloat(max(1, actionViews.count)) * buttonDimension
                + horizontalPadding * 2,
            height: buttonDimension
        )
    }

}

@MainActor
private final class OnlineSourceDownloadQueueViewController: UIViewController,
    UITableViewDataSource
{
    private enum Row: Hashable {
        case download(SourceObjectID)
        case `import`(SourceObjectID)
    }

    private let model: OnlineSourcesSceneModel
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var observationTask: Task<Void, Never>?
    private var sourceObservationTask: Task<Void, Never>?
    private var rowIDs: [Row] = []
    private var snapshotsByRow: [Row: String] = [:]
    private var latestSnapshot = OnlineDownloadQueueSnapshot()

    init(model: OnlineSourcesSceneModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = L("下载任务")
        restorationIdentifier = "onlineSources.downloadQueue.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "onlineSources.downloadQueue.view"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "QueueCell")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("取消全部"),
            style: .plain,
            target: self,
            action: #selector(cancelAll)
        )
        observeQueue()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observationTask?.cancel()
        observationTask = nil
        sourceObservationTask?.cancel()
        sourceObservationTask = nil
    }

    deinit {
        observationTask?.cancel()
        sourceObservationTask?.cancel()
    }

    private func observeQueue() {
        if observationTask == nil {
            let stream = model.downloadQueue.makeSnapshotStream()
            observationTask = Task { @MainActor [weak self] in
                for await snapshot in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.render(snapshot)
                }
            }
        }
        if sourceObservationTask == nil {
            sourceObservationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let stream = await self.model.serving.makeSnapshotStream()
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    // Download rows cache the source display name in their
                    // signature. A source rename therefore only reloads the
                    // affected rows instead of the whole table.
                    self.render(self.latestSnapshot)
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeQueue()
    }

    @objc private func cancelAll() {
        Task { await model.cancelAllDownloads() }
    }

    private func render(_ snapshot: OnlineDownloadQueueSnapshot) {
        latestSnapshot = snapshot
        let nextRows = snapshot.imports.values
            .sorted { left, right in
                left.rootItemID < right.rootItemID
            }
            .map { Row.import($0.rootItemID) }
            + snapshot.downloads.values
                .sorted { left, right in
                    left.itemID < right.itemID
                }
                .map { Row.download($0.itemID) }

        var nextValues: [Row: String] = [:]
        for row in nextRows {
            switch row {
            case .download(let itemID):
                guard let value = snapshot.downloads[itemID] else { continue }
                nextValues[row] = [
                    value.displayName,
                    sourceName(value.itemID.sourceID),
                    downloadPhaseTitle(value.phase),
                    value.failureReason ?? ""
                ].joined(separator: "\u{001F}")
            case .import(let rootItemID):
                guard let value = snapshot.imports[rootItemID] else { continue }
                nextValues[row] = [
                    value.displayName,
                    sourceName(value.rootItemID.sourceID),
                    importPhaseTitle(value.phase),
                    String(value.totalItems),
                    String(value.processedItems),
                    String(value.importedItems),
                    String(value.duplicateItems),
                    String(value.skippedItems),
                    String(value.failedItems),
                    value.currentItemName ?? "",
                    value.failureReason ?? ""
                ].joined(separator: "\u{001F}")
            }
        }

        if nextRows != rowIDs {
            rowIDs = nextRows
            snapshotsByRow = nextValues
            tableView.reloadData()
            return
        }

        let changedIndexes = nextRows.indices.compactMap { index -> IndexPath? in
            let row = nextRows[index]
            return snapshotsByRow[row] == nextValues[row]
                ? nil
                : IndexPath(row: index, section: 0)
        }
        snapshotsByRow = nextValues
        guard !changedIndexes.isEmpty else { return }
        tableView.reloadRows(at: changedIndexes, with: .none)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rowIDs.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "QueueCell", for: indexPath)
        let rowID = rowIDs[indexPath.row]
        var content = cell.defaultContentConfiguration()
        switch rowID {
        case .download(let itemID):
            guard let row = latestSnapshot.downloads[itemID] else { return cell }
            content.text = row.displayName
            content.secondaryText = "\(sourceName(row.itemID.sourceID)) · \(downloadPhaseTitle(row.phase))"
        case .import(let rootItemID):
            guard let row = latestSnapshot.imports[rootItemID] else { return cell }
            content.text = row.displayName
            content.secondaryText = "\(sourceName(row.rootItemID.sourceID)) · \(importPhaseTitle(row.phase))"
        }
        content.image = UIImage(systemName: "arrow.down.circle")
        content.imageProperties.tintColor = MusicFreeUIColorTokens.accent
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "onlineSources.downloadQueue.row.\(indexPath.row)"
        return cell
    }

    private func sourceName(_ sourceID: MediaSourceID) -> String {
        model.snapshot.sources.first(where: { $0.sourceID == sourceID })?.displayName ?? sourceID.rawValue
    }

    private func downloadPhaseTitle(_ phase: OnlineSourceDownloadPhase) -> String {
        switch phase {
        case .downloading: L("正在下载")
        case .importing: L("正在导入媒体库")
        case .completed: L("已完成")
        case .alreadyImported: L("媒体已存在")
        case .skipped: L("已跳过")
        case .cancelled: L("已取消")
        case .failed: L("失败，可重试")
        }
    }

    private func importPhaseTitle(_ phase: OnlineSourceImportPhase) -> String {
        switch phase {
        case .discovering: L("正在扫描目录")
        case .downloading: L("正在下载")
        case .importing: L("正在导入媒体库")
        case .completed: L("已完成")
        case .cancelled: L("已取消")
        case .failed: L("失败，可重试")
        }
    }
}
