import Foundation
import MediaSourceAPI

public enum OnlineDownloadTaskPhase: String, Equatable, Sendable {
    case waiting, discovering, downloading, importing, completed, cancelled, partialFailure, failed
    public var isActive: Bool { [.waiting, .discovering, .downloading, .importing].contains(self) }
}

public struct OnlineDownloadTaskSummary: Equatable, Sendable {
    public let id: SourceObjectID
    public let displayName: String
    public let phase: OnlineDownloadTaskPhase
    public let totalFiles: Int
    public let completedFiles: Int
    public let failedFiles: Int
    public let createdAt: Date?
    public let isRecursive: Bool
    public let failureReason: String?
}

public extension OnlineDownloadQueueSnapshot {
    var tasks: [OnlineDownloadTaskSummary] {
        let groups = Dictionary(grouping: downloads.values.filter { $0.taskID != nil }, by: { $0.taskID! })
        let folderTasks = imports.values.map { value in
            var records = Dictionary((value.files ?? []).map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
            for file in groups[value.rootItemID] ?? [] { records[file.itemID] = file }
            let files = Array(records.values)
            let complete = files.filter(\.isSuccessful).count
            let failed = files.filter { $0.phase == .failed || $0.phase == .cancelled }.count
            let phase: OnlineDownloadTaskPhase
            switch value.phase {
            case .waiting: phase = .waiting
            case .discovering: phase = .discovering
            case .downloading: phase = files.contains { $0.phase == .downloading } ? .downloading : files.contains { $0.phase == .importing } ? .importing : .downloading
            case .importing: phase = .importing
            case .completed: phase = failed > 0 ? .partialFailure : .completed
            case .cancelled: phase = .cancelled
            case .failed: phase = complete > 0 || value.importedItems + value.duplicateItems > 0 ? .partialFailure : .failed
            }
            return OnlineDownloadTaskSummary(id: value.rootItemID, displayName: value.displayName, phase: phase, totalFiles: max(value.totalItems, files.count), completedFiles: files.isEmpty ? value.importedItems + value.duplicateItems + value.skippedItems : complete, failedFiles: files.isEmpty ? value.failedItems : failed, createdAt: value.createdAt, isRecursive: value.isSingleFile != true, failureReason: value.failureReason)
        }
        let singleTasks = downloads.values.filter { $0.taskID == nil }.map { value in
            let files = [value] + (groups[value.itemID] ?? [])
            let phase: OnlineDownloadTaskPhase
            switch value.phase {
            case .waiting: phase = .waiting
            case .downloading: phase = .downloading
            case .importing: phase = .importing
            case .completed, .alreadyImported, .skipped: phase = files.contains { $0.phase == .failed || $0.phase == .cancelled } ? .partialFailure : .completed
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed
            }
            return OnlineDownloadTaskSummary(id: value.itemID, displayName: value.displayName, phase: phase, totalFiles: files.count, completedFiles: files.filter(\.isSuccessful).count, failedFiles: files.filter { $0.phase == .failed || $0.phase == .cancelled }.count, createdAt: value.createdAt, isRecursive: false, failureReason: value.failureReason)
        }
        return (folderTasks + singleTasks).sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    func files(for taskID: SourceObjectID, sorted: Bool = true) -> [OnlineSourceDownloadSnapshot] {
        let latest = downloads.values.filter { $0.taskID == taskID || ($0.taskID == nil && $0.itemID == taskID) }
        var files = Dictionary((imports[taskID]?.files ?? []).map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
        for file in latest { files[file.itemID] = file }
        let records = Array(files.values)
        guard sorted else { return records }
        return records.sorted {
            let left = ($0.relativePath ?? "") + $0.displayName
            let right = ($1.relativePath ?? "") + $1.displayName
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
