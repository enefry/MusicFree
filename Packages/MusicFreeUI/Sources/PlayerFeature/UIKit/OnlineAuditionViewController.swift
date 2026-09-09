import AppServices
import DesignSystem
import UIKit

/// Transient online audition surface. It is deliberately independent from the
/// formal Mini Player and consumes only the audition snapshot stream.
@MainActor
public final class OnlineAuditionViewController: UIViewController {
    private let serving: any OnlineAuditionServing
    private let usesSystemAccessory: Bool
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let surface = UIVisualEffectView(effect: OnlineAuditionViewController.makeGlassEffect())
    private let capsule = UIVisualEffectView(effect: OnlineAuditionViewController.makeGlassEffect())
    private let capsuleTitleLabel = UILabel()
    private let capsulePlayButton = UIButton(type: .system)
    private var task: Task<Void, Never>?
    private var latest = OnlineAuditionSnapshot.idle
    private var isCollapsed = false
    private var isSheetPresented = false
    private var surfaceLeadingConstraint: NSLayoutConstraint!
    private var surfaceTrailingConstraint: NSLayoutConstraint!
    private var surfaceWidthConstraint: NSLayoutConstraint!
    private var surfaceHeightConstraint: NSLayoutConstraint!
    private var capsuleHeightConstraint: NSLayoutConstraint!

    public init(serving: any OnlineAuditionServing, usesSystemAccessory: Bool = false) {
        self.serving = serving
        self.usesSystemAccessory = usesSystemAccessory
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "player.onlineAudition"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeGlassEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect(style: .regular)
        }
        return UIBlurEffect(style: .systemMaterial)
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isHidden = true
        view.accessibilityIdentifier = "player.onlineAudition"
        if usesSystemAccessory {
            surface.effect = nil
            capsule.effect = nil
        }

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.layer.cornerRadius = MusicFreeLayoutMetrics.miniPlayerCornerRadius
        surface.layer.cornerCurve = .continuous
        surface.clipsToBounds = true
        surface.accessibilityIdentifier = "player.onlineAudition.surface"
        view.addSubview(surface)

        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.layer.cornerRadius = MusicFreeLayoutMetrics.miniPlayerCornerRadius
        capsule.layer.cornerCurve = .continuous
        capsule.clipsToBounds = true
        capsule.isHidden = true
        capsule.accessibilityIdentifier = "player.onlineAudition.capsule"
        view.addSubview(capsule)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.accessibilityIdentifier = "player.onlineAudition.title"
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.accessibilityIdentifier = "player.onlineAudition.subtitle"
        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.isUserInteractionEnabled = true
        labels.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(showQueue))
        )

        configure(playButton, image: "play.fill", label: L("播放试听"), identifier: "player.onlineAudition.play")
        configure(queueButton, image: "forward.end.fill", label: L("下一首试听"), identifier: "player.onlineAudition.next")
        configure(collapseButton, image: "chevron.down", label: L("收起试听条"), identifier: "player.onlineAudition.collapse")
        collapseButton.setPreferredSymbolConfiguration(.init(pointSize: 13, weight: .semibold), forImageIn: .normal)
        playButton.setPreferredSymbolConfiguration(.init(pointSize: 20, weight: .semibold), forImageIn: .normal)
        queueButton.setPreferredSymbolConfiguration(.init(pointSize: 18, weight: .semibold), forImageIn: .normal)
        [playButton, queueButton, collapseButton].forEach { button in
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        playButton.addTarget(self, action: #selector(toggle), for: .primaryActionTriggered)
        queueButton.addTarget(self, action: #selector(advance), for: .primaryActionTriggered)
        collapseButton.addTarget(self, action: #selector(toggleCollapsed), for: .primaryActionTriggered)

        let controls = UIStackView(arrangedSubviews: [playButton, queueButton])
        controls.axis = .horizontal
        controls.spacing = 2
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        [labels, controls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let row = UIStackView(arrangedSubviews: [collapseButton, labels, controls])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(row)
        surfaceLeadingConstraint = surface.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: MusicFreeLayoutMetrics.miniPlayerHorizontalInset
        )
        surfaceTrailingConstraint = surface.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: -MusicFreeLayoutMetrics.miniPlayerHorizontalInset
        )
        surfaceWidthConstraint = surface.widthAnchor.constraint(equalToConstant: 420)
        surfaceHeightConstraint = surface.heightAnchor.constraint(
            equalToConstant: preferredBarHeight
        )
        NSLayoutConstraint.activate([
            surfaceLeadingConstraint,
            surfaceTrailingConstraint,
            surface.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            surfaceHeightConstraint,
            row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: surface.contentView.topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: surface.contentView.bottomAnchor),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            queueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            collapseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            queueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            collapseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
        ])

        for constraint in queueButton.constraints + collapseButton.constraints
        where constraint.firstAttribute == .width {
            constraint.priority = .defaultHigh
        }

        let capsuleStack = UIStackView(arrangedSubviews: [capsuleTitleLabel, capsulePlayButton])
        capsuleStack.axis = .horizontal
        capsuleStack.alignment = .center
        capsuleStack.spacing = 8
        capsuleStack.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(capsuleStack)
        capsuleTitleLabel.font = .preferredFont(forTextStyle: usesSystemAccessory ? .subheadline : .caption1)
        capsuleTitleLabel.textColor = .label
        capsuleTitleLabel.numberOfLines = 1
        capsuleTitleLabel.accessibilityIdentifier = "player.onlineAudition.capsule.title"
        configure(capsulePlayButton, image: "play.fill", label: L("播放试听"), identifier: "player.onlineAudition.capsule.play")
        capsulePlayButton.addTarget(self, action: #selector(toggle), for: .primaryActionTriggered)
        let capsuleTap = UITapGestureRecognizer(target: self, action: #selector(expand))
        capsuleTap.cancelsTouchesInView = false
        capsule.addGestureRecognizer(capsuleTap)
        capsulePlayButton.translatesAutoresizingMaskIntoConstraints = false
        capsulePlayButton.widthAnchor.constraint(
            equalToConstant: MusicFreeLayoutMetrics.minimumHitTarget
        ).isActive = true
        capsulePlayButton.heightAnchor.constraint(
            greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget
        ).isActive = true
        capsuleHeightConstraint = capsule.heightAnchor.constraint(
            equalToConstant: preferredCapsuleHeight
        )
        NSLayoutConstraint.activate([
            usesSystemAccessory
                ? capsule.leadingAnchor.constraint(equalTo: view.leadingAnchor)
                : capsule.widthAnchor.constraint(equalToConstant: 160),
            capsuleHeightConstraint,
            capsule.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: usesSystemAccessory ? 0 : -MusicFreeLayoutMetrics.miniPlayerHorizontalInset
            ),
            capsule.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            capsuleStack.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 14),
            capsuleStack.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -8),
            capsuleStack.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            capsuleStack.topAnchor.constraint(greaterThanOrEqualTo: capsule.contentView.topAnchor),
            capsuleStack.bottomAnchor.constraint(lessThanOrEqualTo: capsule.contentView.bottomAnchor),
        ])
        render(serving.snapshot)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        let stream = serving.makeSnapshotStream()
        task = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.render(snapshot)
            }
        }
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySurfaceLayout()
        updateBarHeights()
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applySurfaceLayout()
        updateBarHeights()
    }

    private func applySurfaceLayout() {
        let isRegular = traitCollection.horizontalSizeClass == .regular && !usesSystemAccessory
        if !isRegular { surfaceWidthConstraint.isActive = false }
        surfaceLeadingConstraint.constant = usesSystemAccessory ? 0 : MusicFreeLayoutMetrics.miniPlayerHorizontalInset
        surfaceTrailingConstraint.constant = usesSystemAccessory ? 0 : -MusicFreeLayoutMetrics.miniPlayerHorizontalInset
        surfaceLeadingConstraint.isActive = !isRegular
        surfaceTrailingConstraint.isActive = true
        surfaceWidthConstraint.constant = min(
            420,
            max(0, view.bounds.width - MusicFreeLayoutMetrics.miniPlayerHorizontalInset * 2)
        )
        surfaceWidthConstraint.isActive = isRegular
        let isInline: Bool
        if #available(iOS 26.0, *) {
            isInline = usesSystemAccessory && view.traitCollection.tabAccessoryEnvironment == .inline
        } else {
            isInline = false
        }
        subtitleLabel.isHidden = isInline
        collapseButton.isHidden = isInline
        queueButton.isHidden = isInline
    }

    private var preferredBarHeight: CGFloat {
        // Keep the visual surface aligned with the formal Mini Player. The
        // root controller still reserves the stable 64pt legacy slot around
        // this view, so changing the visual height does not move page content.
        if #available(iOS 26.0, *) {
            return view.traitCollection.tabAccessoryEnvironment == .inline
                ? MusicFreeLayoutMetrics.miniPlayerInlineHeight
                : MusicFreeLayoutMetrics.miniPlayerContentHeight
        }
        return MusicFreeLayoutMetrics.miniPlayerLegacyHeight
    }

    private var preferredCapsuleHeight: CGFloat { usesSystemAccessory ? preferredBarHeight : 52 }

    private func updateBarHeights() {
        guard surfaceHeightConstraint != nil, capsuleHeightConstraint != nil else { return }
        surfaceHeightConstraint.constant = preferredBarHeight
        capsuleHeightConstraint.constant = preferredCapsuleHeight
    }

    private func configure(_ button: UIButton, image: String, label: String, identifier: String? = nil) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.preferredBehavioralStyle = .pad
    }

    private func render(_ snapshot: OnlineAuditionSnapshot) {
        if !snapshot.hasRetainedSession { isCollapsed = false }
        latest = snapshot
        let visible = snapshot.hasRetainedSession
        view.isHidden = !visible
        surface.isHidden = !visible || isCollapsed || isSheetPresented
        capsule.isHidden = !visible || !isCollapsed || isSheetPresented
        titleLabel.text = snapshot.displayName ?? L("在线试听")
        subtitleLabel.text = [auditionStatus(snapshot), snapshot.artist, snapshot.sourceDisplayName]
            .compactMap { $0 }
            .joined(separator: " · ")
        queueButton.isEnabled = snapshot.canNext
        playButton.isEnabled = snapshot.phase != .preparing
        capsulePlayButton.isEnabled = snapshot.phase != .preparing
        playButton.setImage(UIImage(systemName: snapshot.phase == .playing ? "pause.fill" : "play.fill"), for: .normal)
        capsuleTitleLabel.text = snapshot.displayName ?? L("在线试听")
        switch snapshot.phase {
        case .failed:
            playButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
            capsulePlayButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
            playButton.accessibilityLabel = L("重试试听")
        case .ended:
            playButton.setImage(UIImage(systemName: "gobackward"), for: .normal)
            capsulePlayButton.setImage(UIImage(systemName: "gobackward"), for: .normal)
            playButton.accessibilityLabel = L("重新试听")
        default:
            let image = snapshot.phase == .playing ? "pause.fill" : "play.fill"
            playButton.setImage(UIImage(systemName: image), for: .normal)
            capsulePlayButton.setImage(UIImage(systemName: image), for: .normal)
            playButton.accessibilityLabel = snapshot.phase == .playing ? L("暂停试听") : L("继续试听")
        }
        capsulePlayButton.accessibilityLabel = playButton.accessibilityLabel
    }

    @objc private func toggle() { Task { if latest.phase == .failed || latest.phase == .ended { try? await serving.retry() } else if latest.phase == .playing { await serving.pause() } else { try? await serving.resume() } } }
    @objc private func toggleCollapsed() {
        isCollapsed.toggle()
        render(latest)
    }

    @objc private func advance() { Task { try? await serving.next() } }
    @objc private func expand(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: capsule)
        guard !capsulePlayButton.convert(capsulePlayButton.bounds, to: capsule).contains(point) else { return }
        isCollapsed = false
        render(latest)
    }

    @objc private func showQueue() {
        guard presentedViewController == nil else { return }
        let controller = OnlineAuditionQueueViewController(serving: serving)
        controller.onDismiss = { [weak self] in
            guard let self else { return }
            self.isSheetPresented = false
            self.render(self.serving.snapshot)
        }
        let nav = UINavigationController(rootViewController: controller)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        isSheetPresented = true
        render(latest)
        present(nav, animated: true) { [weak self, weak nav] in
            guard let self, let nav else { return }
            nav.presentationController?.delegate = self
        }
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard !usesSystemAccessory, let window = view.window,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let keyboardFrame = window.convert(frame, from: nil)
        let viewFrame = view.convert(view.bounds, to: window)
        let overlap = max(0, viewFrame.maxY - keyboardFrame.minY)
        let translation = overlap > 0 ? -(overlap + 8) : 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)
            .map { $0.doubleValue } ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.surface.transform = CGAffineTransform(translationX: 0, y: translation)
            self.capsule.transform = CGAffineTransform(translationX: 0, y: translation)
        }
    }

    private func accessibilityTimeValue(position: Int64, duration: Int64?) -> String {
        let positionText = formatTime(position)
        guard let duration else { return positionText }
        return "\(positionText) / \(formatTime(duration))"
    }

    private func formatTime(_ seconds: Int64) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func auditionStatus(_ snapshot: OnlineAuditionSnapshot) -> String? {
        switch snapshot.phase {
        case .preparing: L("连接中")
        case .buffering: L("缓冲中")
        case .playing: L("试听中")
        case .paused: L("已暂停")
        case .ended: L("播放结束")
        case .failed: L("试听失败")
        case .idle, .stopped: nil
        }
    }
}

extension OnlineAuditionViewController: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isSheetPresented = false
        render(latest)
    }
}

@MainActor
private final class OnlineAuditionQueueViewController: UITableViewController {
    var onDismiss: (() -> Void)?
    private let serving: any OnlineAuditionServing
    private var snapshot: OnlineAuditionSnapshot
    private let currentTitleLabel = UILabel()
    private let currentSubtitleLabel = UILabel()
    private let failureLabel = UILabel()
    private let footerLabel = UILabel()
    private let headerSlider = UISlider()
    private let previousButton = UIButton(type: .system)
    private let mainButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let headerView = UIView()
    private var streamTask: Task<Void, Never>?
    private var isScrubbing = false

    init(serving: any OnlineAuditionServing) {
        self.serving = serving
        snapshot = serving.snapshot
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("试听")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
            style: .plain,
            target: self,
            action: #selector(dismissSheetOnly)
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = L("收起试听面板")
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "player.onlineAudition.sheet.dismiss"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("结束试听"),
            style: .done,
            target: self,
            action: #selector(endAudition)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = L("结束试听")
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "player.onlineAudition.sheet.close"

        currentTitleLabel.font = .preferredFont(forTextStyle: .title2)
        currentTitleLabel.numberOfLines = 2
        currentSubtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        currentSubtitleLabel.textColor = .secondaryLabel
        currentSubtitleLabel.numberOfLines = 1
        failureLabel.font = .preferredFont(forTextStyle: .footnote)
        failureLabel.textColor = .systemRed
        failureLabel.numberOfLines = 0
        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.textColor = .secondaryLabel
        footerLabel.numberOfLines = 0
        headerSlider.addTarget(self, action: #selector(beginSeeking), for: .touchDown)
        headerSlider.addTarget(self, action: #selector(endSeeking), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        headerSlider.accessibilityLabel = L("试听进度")
        headerSlider.accessibilityIdentifier = "player.onlineAudition.sheet.progress"
        configure(previousButton, image: "backward.fill", label: L("上一首试听"), identifier: "player.onlineAudition.sheet.previous")
        configure(mainButton, image: "play.fill", label: L("播放试听"), identifier: "player.onlineAudition.sheet.play")
        configure(nextButton, image: "forward.fill", label: L("下一首试听"), identifier: "player.onlineAudition.sheet.next")
        previousButton.addTarget(self, action: #selector(previous), for: .primaryActionTriggered)
        mainButton.addTarget(self, action: #selector(toggle), for: .primaryActionTriggered)
        nextButton.addTarget(self, action: #selector(advance), for: .primaryActionTriggered)

        let controls = UIStackView(arrangedSubviews: [previousButton, mainButton, nextButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .equalCentering
        let stack = UIStackView(arrangedSubviews: [currentTitleLabel, currentSubtitleLabel, failureLabel, headerSlider, controls])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        headerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 204)
        headerView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),
            controls.heightAnchor.constraint(equalToConstant: 48),
        ])
        footerLabel.frame = CGRect(x: 20, y: 8, width: max(0, tableView.bounds.width - 40), height: 44)
        render(snapshot)
        let stream = serving.makeSnapshotStream()
        streamTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled, let self else { return }
                let queueChanged = self.snapshot.queue != snapshot.queue
                    || self.snapshot.itemID != snapshot.itemID
                self.snapshot = snapshot
                self.render(snapshot)
                if queueChanged { self.tableView.reloadData() }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var frame = headerView.frame
        frame.size.width = tableView.bounds.width
        if tableView.tableHeaderView == nil {
            headerView.frame = frame
            tableView.tableHeaderView = headerView
        } else if headerView.frame != frame {
            // UITableView only needs the header object's frame updated after
            // the initial mount. Reassigning tableHeaderView here can trigger
            // a layout pass while the sheet is presenting.
            headerView.frame = frame
        }
        var footerFrame = footerLabel.frame
        footerFrame.size.width = max(0, tableView.bounds.width - 40)
        if tableView.tableFooterView == nil {
            footerLabel.frame = footerFrame
            tableView.tableFooterView = footerLabel
        } else if footerLabel.frame != footerFrame {
            footerLabel.frame = footerFrame
        }
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); snapshot = serving.snapshot; render(snapshot); tableView.reloadData() }
    deinit { streamTask?.cancel() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { snapshot.queue.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let item = snapshot.queue[indexPath.row]
        cell.textLabel?.text = item.title ?? item.displayName
        cell.detailTextLabel?.text = item.artist
        cell.accessoryType = item.id == snapshot.itemID ? .checkmark : .none
        cell.accessibilityIdentifier = "player.onlineAudition.queue.\(item.id.externalID)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { Task { try? await serving.select(itemID: snapshot.queue[indexPath.row].id); snapshot = serving.snapshot; tableView.reloadData() } }
    private func configure(_ button: UIButton, image: String, label: String, identifier: String? = nil) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.preferredBehavioralStyle = .pad
    }

    private func render(_ snapshot: OnlineAuditionSnapshot) {
        currentTitleLabel.text = snapshot.displayName ?? L("在线试听")
        currentSubtitleLabel.text = [auditionStatus(snapshot), snapshot.artist, snapshot.album, snapshot.sourceDisplayName]
            .compactMap { $0 }
            .joined(separator: " · ")
        headerSlider.maximumValue = Float(max(1, snapshot.duration?.components.seconds ?? 0))
        if !isScrubbing {
            headerSlider.value = Float(snapshot.position.components.seconds)
        }
        headerSlider.isEnabled = snapshot.canSeek
        headerSlider.accessibilityValue = accessibilityTimeValue(
            position: snapshot.position.components.seconds,
            duration: snapshot.duration?.components.seconds
        )
        previousButton.isEnabled = snapshot.canPrevious
        nextButton.isEnabled = snapshot.canNext
        mainButton.isEnabled = snapshot.phase != .preparing
        let isRetry = snapshot.phase == .failed || snapshot.phase == .ended
        mainButton.setImage(
            UIImage(systemName: isRetry
                ? (snapshot.phase == .failed ? "arrow.clockwise" : "gobackward")
                : (snapshot.phase == .playing ? "pause.fill" : "play.fill")),
            for: .normal
        )
        mainButton.accessibilityLabel = isRetry
            ? (snapshot.phase == .failed ? L("重试试听") : L("重新试听"))
            : (snapshot.phase == .playing ? L("暂停试听") : L("继续试听"))
        failureLabel.text = snapshot.failureReason
        failureLabel.isHidden = snapshot.failureReason == nil
        footerLabel.text = snapshot.queue.isEmpty
            ? nil
            : L("共 \(snapshot.queue.count) 首 · 仅本次已加载歌曲；顺序播放，播放完毕后停止")
    }

    @objc private func beginSeeking() { isScrubbing = true }
    @objc private func endSeeking() {
        guard isScrubbing else { return }
        isScrubbing = false
        let value = headerSlider.value
        Task { try? await serving.seek(to: .seconds(Int64(value))) }
    }

    @objc private func previous() { Task { try? await serving.previous() } }
    @objc private func advance() { Task { try? await serving.next() } }
    @objc private func toggle() { Task { if snapshot.phase == .playing { await serving.pause() } else if snapshot.canRetry { try? await serving.retry() } else { try? await serving.resume() } } }
    @objc private func dismissSheetOnly() { dismiss(animated: true, completion: onDismiss) }

    @objc private func endAudition() {
        Task {
            await serving.close()
            dismiss(animated: true, completion: onDismiss)
        }
    }

    private func accessibilityTimeValue(position: Int64, duration: Int64?) -> String {
        let positionText = formatTime(position)
        guard let duration else { return positionText }
        return "\(positionText) / \(formatTime(duration))"
    }

    private func formatTime(_ seconds: Int64) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func auditionStatus(_ snapshot: OnlineAuditionSnapshot) -> String? {
        switch snapshot.phase {
        case .preparing: L("连接中")
        case .buffering: L("缓冲中")
        case .playing: L("试听中")
        case .paused: L("已暂停")
        case .ended: L("播放结束")
        case .failed: L("试听失败")
        case .idle, .stopped: nil
        }
    }
}
