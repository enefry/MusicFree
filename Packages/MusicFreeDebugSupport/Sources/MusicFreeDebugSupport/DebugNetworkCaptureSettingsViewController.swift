import DesignSystem
import UIKit

#if DEBUG && canImport(Pulse)
import CoreData
import Pulse
#endif

@MainActor
public final class DebugNetworkCaptureSettingsViewController: UITableViewController {
    private let enabled = UISwitch()
    public init() { super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L("网络抓包")
        enabled.isOn = UserDefaults.standard.bool(forKey: DebugNetworkCapture.enabledDefaultsKey)
        enabled.isEnabled = DebugNetworkCapture.isAvailable
        enabled.accessibilityIdentifier = "settings.debug.networkCapture.toggle"
        enabled.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = L(indexPath.row == 0 ? "网络抓包 (DEBUG)" : "查看网络请求")
        if indexPath.row == 0 { cell.accessoryView = enabled; cell.selectionStyle = .none }
        else { cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "settings.debug.networkCapture.console"; cell.isUserInteractionEnabled = enabled.isOn && DebugNetworkCapture.isAvailable; cell.contentView.alpha = cell.isUserInteractionEnabled ? 1 : 0.5 }
        return cell
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        enabled.isOn ? L("抓包已开启。关闭后需重启 App 才会停止本次运行中的抓包。请求数据仅保存在本机。") : L("开启后记录 URLSession 网络请求；默认关闭，仅 Debug 构建可用。")
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
#if DEBUG && canImport(Pulse)
        guard indexPath.row == 1, enabled.isOn else { return }
        navigationController?.pushViewController(DebugNetworkRequestsViewController(), animated: true)
#endif
    }
    @objc private func toggleChanged() {
        UserDefaults.standard.set(enabled.isOn, forKey: DebugNetworkCapture.enabledDefaultsKey)
        if enabled.isOn { DebugNetworkCapture.enable() }
        tableView.reloadData()
    }
}

#if DEBUG && canImport(Pulse)
@MainActor
private final class DebugNetworkRequestsViewController: UITableViewController, @preconcurrency NSFetchedResultsControllerDelegate, UISearchResultsUpdating {
    private var results: NSFetchedResultsController<NetworkTaskEntity>!
    private let search = UISearchController(searchResultsController: nil)
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("网络请求")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        definesPresentationContext = true
        let request = NSFetchRequest<NetworkTaskEntity>(entityName: "NetworkTaskEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchBatchSize = 50
        results = NSFetchedResultsController(fetchRequest: request, managedObjectContext: LoggerStore.shared.viewContext, sectionNameKeyPath: nil, cacheName: nil)
        results.delegate = self
        fetch()
    }
    private func fetch() {
        do { try results.performFetch(); tableView.reloadData() }
        catch {
            let alert = UIAlertController(title: L("网络请求"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(.init(title: L("确定"), style: .default)); present(alert, animated: true)
        }
    }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        results.fetchRequest.predicate = text.isEmpty ? nil : NSPredicate(format: "url CONTAINS[cd] %@", text)
        fetch()
    }
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) { tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results?.fetchedObjects?.count ?? 0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = results.object(at: indexPath)
        let cell = tableView.dequeueReusableCell(withIdentifier: "request") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "request")
        cell.textLabel?.text = "\(entry.httpMethod ?? "") \(entry.url ?? "")"
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = "\(entry.statusCode) · \(String(format: "%.3f s", entry.duration)) · \(entry.formattedTimestamp)"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = results.object(at: indexPath)
        let request = entry.currentRequest ?? entry.originalRequest
        let headers: ([String: String]?) -> String = { $0?.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? "" }
        let body: (Data?) -> String = { data in
            guard let data else { return "" }
            return String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
        }
        let text = ["\(entry.httpMethod ?? "") \(entry.url ?? "")", "Status: \(entry.statusCode)", "Duration: \(entry.duration) s", entry.errorDebugDescription ?? "", "Request headers\n" + headers(request?.headers), "Request body\n" + body(entry.requestBody?.data), "Response headers\n" + headers(entry.response?.headers), "Response body\n" + body(entry.responseBody?.data)].joined(separator: "\n\n")
        navigationController?.pushViewController(DebugNetworkRequestDetailViewController(text: text), animated: true)
    }
}

@MainActor
private final class DebugNetworkRequestDetailViewController: UIViewController {
    private let text: String
    init(text: String) { self.text = text; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("网络请求")
        let content = UITextView()
        content.isEditable = false
        content.text = text
        content.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor), content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }
}
#endif
