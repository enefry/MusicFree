import DesignSystem
import Observation
import UIKit

/// Optional native form support for companions. A companion may instead return
/// any UIViewController, including custom controls and nested navigation.
@MainActor
open class PluginSettingsFormViewController: UITableViewController {
    public struct Section {
        public let id: String
        public let title: String
        public let footer: String
        public let rows: [SettingsNativeRow]
        public init(id: String, title: String, footer: String = "", rows: [SettingsNativeRow]) {
            self.id = id; self.title = title; self.footer = footer; self.rows = rows
        }
    }
    public private(set) var rows: [String: SettingsNativeRow] = [:]
    private var sections: [Section] = []
    private var dataSource: SettingsNativeDataSource!
    private var observationGeneration = 0

    public init() { super.init(style: .insetGrouped) }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    open var canEdit: Bool { true }
    open func makeSections() -> [Section] { [] }

    open override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(SettingsNativeCell.self, forCellReuseIdentifier: "pluginForm")
        dataSource = SettingsNativeDataSource(tableView: tableView) { [weak self] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "pluginForm", for: path) as! SettingsNativeCell
            if let row = self?.rows[id] { cell.configure(row) }
            return cell
        }
        dataSource.sectionText = { [weak self] index, footer in
            guard let self, self.sections.indices.contains(index) else { return nil }
            let section = self.sections[index]
            let text = footer ? section.footer : section.title
            return text.isEmpty ? nil : text
        }
        render()
    }
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        render()
    }
    open override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? { tableView }

    public func render() {
        guard isViewLoaded else { return }
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
        for cell in tableView.visibleCells {
            guard let cell = cell as? SettingsNativeCell, let id = cell.rowID, let row = rows[id] else { continue }
            cell.configure(row)
        }
    }

    open override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id], row.enabled else { return }
        row.action?()
    }
    public func text(_ id: String, _ title: String, detail: String = "") -> SettingsNativeRow { .init(id: id, title: title, detail: detail) }
    public func action(_ id: String, _ title: String, detail: String = "", symbol: String? = nil, disclosure: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, detail: detail, image: symbol.flatMap { UIImage(systemName: $0) }, disclosure: disclosure, destructive: destructive, action: action)
    }
    public func toggle(_ id: String, _ title: String, value: Bool, change: @escaping (Bool) -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, enabled: canEdit, control: .toggle(value, change))
    }
    public func menu(_ id: String, _ title: String, value: String, options: [UIAction]) -> SettingsNativeRow {
        .init(id: id, title: title, enabled: canEdit, control: .menu(value, UIMenu(children: options)))
    }
    public func slider(_ id: String, _ title: String, value: Double, range: ClosedRange<Double>, step: Double, valueText: String, enabled: Bool = true, format: @escaping (Double) -> String, save: @escaping (Double) -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, detail: valueText, enabled: enabled && canEdit, control: .slider(value, range, step, format, save))
    }
}
