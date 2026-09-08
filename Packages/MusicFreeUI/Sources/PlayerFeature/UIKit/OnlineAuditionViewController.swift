import AppServices
import DesignSystem
import UIKit

/// Transient online audition surface. It is deliberately independent from the
/// formal Mini Player and consumes only the audition snapshot stream.
@MainActor
public final class OnlineAuditionViewController: UIViewController {
    private let serving: any OnlineAuditionServing
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progress = UISlider()
    private let playButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var task: Task<Void, Never>?
    private var latest = OnlineAuditionSnapshot.idle

    public init(serving: any OnlineAuditionServing) {
        self.serving = serving
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "player.onlineAudition"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isHidden = true
        view.accessibilityIdentifier = "player.onlineAudition"

        let surface = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.layer.cornerRadius = 16
        surface.clipsToBounds = true
        view.addSubview(surface)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 1

        configure(playButton, image: "play.fill", label: L("播放试听"))
        configure(queueButton, image: "list.bullet", label: L("试听队列"))
        configure(closeButton, image: "xmark", label: L("关闭试听"))
        playButton.addTarget(self, action: #selector(toggle), for: .primaryActionTriggered)
        queueButton.addTarget(self, action: #selector(showQueue), for: .primaryActionTriggered)
        closeButton.addTarget(self, action: #selector(close), for: .primaryActionTriggered)

        progress.minimumValue = 0
        progress.addTarget(self, action: #selector(seek), for: .valueChanged)
        progress.accessibilityLabel = L("试听进度")
        let controls = UIStackView(arrangedSubviews: [playButton, queueButton, closeButton])
        controls.axis = .horizontal
        controls.spacing = 8
        controls.setCustomSpacing(12, after: queueButton)
        [labels, progress, controls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        surface.contentView.addSubview(labels)
        surface.contentView.addSubview(progress)
        surface.contentView.addSubview(controls)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            surface.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            labels.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 14),
            labels.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
            progress.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: labels.trailingAnchor, constant: 8),
            progress.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 90),
            controls.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: 10),
            controls.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -10)
        ])
        render(serving.snapshot)
        let stream = serving.makeSnapshotStream()
        task = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.render(snapshot)
            }
        }
    }

    deinit { task?.cancel() }

    private func configure(_ button: UIButton, image: String, label: String) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = label
        button.preferredBehavioralStyle = .pad
    }

    private func render(_ snapshot: OnlineAuditionSnapshot) {
        latest = snapshot
        let visible = snapshot.phase != .idle && snapshot.phase != .stopped
        view.isHidden = !visible
        titleLabel.text = snapshot.displayName ?? L("在线试听")
        subtitleLabel.text = [snapshot.artist, snapshot.sourceDisplayName].compactMap { $0 }.joined(separator: " · ")
        let duration = snapshot.duration?.components.seconds ?? 0
        progress.maximumValue = Float(max(1, duration))
        progress.value = Float(snapshot.position.components.seconds)
        playButton.setImage(UIImage(systemName: snapshot.phase == .playing ? "pause.fill" : "play.fill"), for: .normal)
        if snapshot.phase == .failed { playButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal); playButton.accessibilityLabel = L("重试试听") }
        if snapshot.phase == .ended { playButton.setImage(UIImage(systemName: "gobackward"), for: .normal); playButton.accessibilityLabel = L("重新试听") }
    }

    @objc private func toggle() { Task { if latest.phase == .failed || latest.phase == .ended { try? await serving.retry() } else if latest.phase == .playing { await serving.pause() } else { try? await serving.resume() } } }
    @objc private func seek() { Task { try? await serving.seek(to: .seconds(Int64(progress.value))) } }
    @objc private func close() { Task { await serving.close() } }
    @objc private func showQueue() {
        let controller = OnlineAuditionQueueViewController(serving: serving)
        let nav = UINavigationController(rootViewController: controller)
        if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(nav, animated: true)
    }
}

@MainActor
private final class OnlineAuditionQueueViewController: UITableViewController {
    private let serving: any OnlineAuditionServing
    private var snapshot: OnlineAuditionSnapshot
    init(serving: any OnlineAuditionServing) { self.serving = serving; snapshot = serving.snapshot; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = L("试听队列"); navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done)); tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell") }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); snapshot = serving.snapshot; tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { snapshot.queue.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath); let item = snapshot.queue[indexPath.row]; cell.textLabel?.text = item.title ?? item.displayName; cell.detailTextLabel?.text = item.artist; cell.accessoryType = item.id == snapshot.itemID ? .checkmark : .none; return cell }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { Task { try? await serving.select(itemID: snapshot.queue[indexPath.row].id); snapshot = serving.snapshot; tableView.reloadData() } }
    @objc private func done() { dismiss(animated: true) }
}
