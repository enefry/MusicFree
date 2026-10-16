import DesignSystem
import Foundation
import SettingsAPI

enum CacheLimitSliderScale {
    private static let megabyte: Int64 = 1_000_000
    private static let gigabyte: Int64 = 1_000_000_000

    static func position(for bytes: Int64, maximumBytes: Int64) -> Double {
        let minimumBytes = StorageByteLimit.minimumBytes
        guard maximumBytes > minimumBytes else { return 0 }
        let clampedBytes = min(max(bytes, minimumBytes), maximumBytes)
        let normalized = Double(clampedBytes - minimumBytes)
            / Double(maximumBytes - minimumBytes)
        return normalized.squareRoot()
    }

    static func bytes(for position: Double, maximumBytes: Int64) -> Int64 {
        let minimumBytes = StorageByteLimit.minimumBytes
        guard maximumBytes > minimumBytes else { return minimumBytes }

        let clampedPosition = min(max(position, 0), 1)
        if clampedPosition == 0 { return minimumBytes }
        if clampedPosition == 1 { return maximumBytes }

        let normalized = clampedPosition * clampedPosition
        let rawBytes = Double(minimumBytes)
            + normalized * Double(maximumBytes - minimumBytes)
        let step = rawBytes < Double(gigabyte) ? 100 * megabyte : gigabyte
        let roundedBytes = (rawBytes / Double(step)).rounded() * Double(step)
        return min(max(Int64(roundedBytes), minimumBytes), maximumBytes)
    }

    static func text(for bytes: Int64) -> String {
        let usesGigabytes = bytes >= gigabyte
        let unit = usesGigabytes ? gigabyte : megabyte
        let value = Int64((Double(bytes) / Double(unit)).rounded())
        return "\(value.formatted()) \(usesGigabytes ? "GB" : "MB")"
    }
}

extension StorageMaintenanceAction {
    var title: String {
        switch self {
        case .clearImportStaging: return L("清理导入暂存")
        case .repairPendingRemovals: return L("修复待删除项目")
        case .clearFinalizedQuarantine: return L("清理已完成隔离")
        }
    }

    var systemImage: String {
        switch self {
        case .clearImportStaging: return "trash"
        case .repairPendingRemovals: return "checkmark.circle"
        case .clearFinalizedQuarantine: return "archivebox"
        }
    }

    var detail: String {
        switch self {
        case .clearImportStaging:
            return L("删除导入流程留下的暂存副本。只处理暂存目录，不影响已经进入资料库的媒体文件。")
        case .repairPendingRemovals:
            return L("检查未完成的删除事务，并根据资料库记录恢复或完成事务。不会重新删除资料库中的媒体文件。")
        case .clearFinalizedQuarantine:
            return L("删除已经完成处理的隔离副本，保留仍处于 pending 状态的文件。清理后不能从隔离目录恢复这些副本。")
        }
    }

    var expectation: String {
        switch self {
        case .clearImportStaging:
            return L("清理完成后，导入暂存占用会减少，存储状态会更新；正在进行的导入会等待维护完成。")
        case .repairPendingRemovals:
            return L("待删除项目会逐项核对；可恢复或可完成的事务会被处理，仍无法判断的事务会保留。")
        case .clearFinalizedQuarantine:
            return L("清理完成后，隔离文件占用会减少；pending 隔离文件会保留，不会被清理。")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .clearImportStaging: return "settings.storage.clearStaging"
        case .repairPendingRemovals: return "settings.storage.repairRemovals"
        case .clearFinalizedQuarantine: return "settings.storage.clearQuarantine"
        }
    }
}
