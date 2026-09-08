import Foundation
import os.log
import CocoaLumberjackSwift

/// The current application log file managed by CocoaLumberjack.
/// The file is disabled by default and is enabled by the app composition root
/// from persisted user settings.
public struct MusicLogFileStatus: Equatable, Sendable {
    public static let defaultMaximumByteCount: Int64 = 4 * 1_024 * 1_024

    public let fileURL: URL?
    public let byteCount: Int64
    public let maximumByteCount: Int64
    public let isEnabled: Bool

    public init(
        fileURL: URL? = nil,
        byteCount: Int64 = 0,
        maximumByteCount: Int64 = Self.defaultMaximumByteCount,
        isEnabled: Bool = false
    ) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.maximumByteCount = maximumByteCount
        self.isEnabled = isEnabled
    }

    public var isAvailable: Bool {
        fileURL != nil && byteCount > 0
    }
}

/// Shared application logging facade. Call sites keep writing to the Apple
/// unified logging system while the same messages can optionally be persisted
/// to a redacted rolling file.
public struct MusicLogger: Sendable {
    public static let subsystem = "com.musicfree.app"
    public static let fileName = "musicfree.log"

    private let systemLogger: OSLog
    private let category: String

    public init(
        subsystem: String = MusicLogger.subsystem,
        category: String
    ) {
        self.systemLogger = OSLog(subsystem: subsystem, category: category)
        self.category = category
    }

    public func debug(_ message: String) {
        log(message, level: .debug)
    }

    public func info(_ message: String) {
        log(message, level: .info)
    }

    public func notice(_ message: String) {
        log(message, level: .notice)
    }

    public func warning(_ message: String) {
        log(message, level: .warning)
    }

    public func error(_ message: String) {
        log(message, level: .error)
    }

    public func fault(_ message: String) {
        log(message, level: .fault)
    }

    /// Configures the one rolling file used by all logger instances.
    public static func configureFileLogging(
        fileURL: URL,
        enabled: Bool,
        maximumByteCount: Int64 = MusicLogFileStatus.defaultMaximumByteCount
    ) {
        MusicLogCoordinator.shared.configure(
            fileURL: fileURL,
            enabled: enabled,
            maximumByteCount: maximumByteCount
        )
    }

    public static func setFileLoggingEnabled(_ enabled: Bool) {
        MusicLogCoordinator.shared.setEnabled(enabled)
    }

    public static func fileLogStatus() -> MusicLogFileStatus {
        MusicLogCoordinator.shared.status()
    }

    /// Waits until all queued file writes have reached disk before sharing.
    public static func flushFileLog() async {
        MusicLogCoordinator.shared.flush()
    }

    private enum Level: String {
        case debug
        case info
        case notice
        case warning
        case error
        case fault
    }

    private func log(_ message: String, level: Level) {
        switch level {
        case .debug:
            os_log("%{public}@", log: systemLogger, type: .debug, message)
        case .info:
            os_log("%{public}@", log: systemLogger, type: .info, message)
        case .notice:
            os_log("%{public}@", log: systemLogger, type: .info, message)
        case .warning:
            os_log("%{public}@", log: systemLogger, type: .error, message)
        case .error:
            os_log("%{public}@", log: systemLogger, type: .error, message)
        case .fault:
            os_log("%{public}@", log: systemLogger, type: .fault, message)
        }

        MusicLogCoordinator.shared.append(
            level: level.rawValue,
            category: category,
            message: message
        )
    }
}

private final class MusicLogCoordinator: @unchecked Sendable {
    static let shared = MusicLogCoordinator()

    private let stateQueue = DispatchQueue(
        label: "com.musicfree.app.file-log-coordinator",
        qos: .utility
    )
    private var ddLog: DDLog?
    private var fileLogger: MusicFileLogger?
    private var fileURL: URL?
    private var enabled = false
    private var maximumByteCount = MusicLogFileStatus.defaultMaximumByteCount

    func configure(fileURL: URL, enabled: Bool, maximumByteCount: Int64) {
        let normalizedMaximum = max(1, maximumByteCount)
        stateQueue.sync {
            let oldDDLog = ddLog
            let oldFileLogger = fileLogger

            oldDDLog?.flushLog()
            if let oldFileLogger {
                oldDDLog?.remove(oldFileLogger)
                oldDDLog?.flushLog()
            }

            let logFileManager = MusicLogFileManager(
                logsDirectory: fileURL.deletingLastPathComponent().path
            )
            let newFileLogger = MusicFileLogger(logFileManager: logFileManager)
            newFileLogger.maximumFileSize = UInt64(normalizedMaximum)
            newFileLogger.maximumNumberOfLogFiles = 1
            newFileLogger.logFilesDiskQuota = 0
            newFileLogger.rollingFrequency = 0
            newFileLogger.logFormatter = MusicLogFileFormatter()

            let newDDLog = DDLog()
            self.ddLog = newDDLog
            self.fileLogger = newFileLogger
            self.fileURL = fileURL
            self.enabled = enabled
            self.maximumByteCount = normalizedMaximum

            if enabled {
                newDDLog.add(newFileLogger, with: .all)
                // Adding a logger is asynchronous. This also establishes the
                // ordering boundary before the first application message.
                newDDLog.flushLog()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        stateQueue.sync {
            guard self.enabled != enabled else { return }
            self.enabled = enabled

            guard let ddLog, let fileLogger else { return }
            if enabled {
                ddLog.add(fileLogger, with: .all)
                ddLog.flushLog()
            } else {
                ddLog.flushLog()
                ddLog.remove(fileLogger)
                ddLog.flushLog()
            }
        }
    }

    func append(level: String, category: String, message: String) {
        guard let logLevel = MusicLogLevel(rawValue: level) else { return }
        let redactedMessage = MusicLogSanitizer.redact(message)
        let logMessage = DDLogMessage(
            "\(redactedMessage)",
            level: logLevel.ddLevel,
            flag: logLevel.ddFlag,
            context: logLevel.context,
            file: #fileID,
            function: #function,
            line: #line,
            tag: category,
            timestamp: Date()
        )

        stateQueue.sync {
            guard enabled, let ddLog else { return }
            ddLog.log(asynchronous: true, message: logMessage)
        }
    }

    func status() -> MusicLogFileStatus {
        stateQueue.sync {
            guard let fileLogger else {
                return MusicLogFileStatus(
                    fileURL: fileURL,
                    maximumByteCount: maximumByteCount,
                    isEnabled: enabled
                )
            }

            let fileInfo: DDLogFileInfo?
            let existingFiles = fileLogger.logFileManager.sortedLogFileInfos
            if existingFiles.isEmpty {
                fileInfo = nil
            } else {
                fileInfo = fileLogger.currentLogFileInfo ?? existingFiles.first
            }

            let currentURL = fileInfo.map { URL(fileURLWithPath: $0.filePath) } ?? fileURL
            let byteCount = currentURL.flatMap { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                    .flatMap { ($0 as? NSNumber)?.int64Value }
            } ?? 0

            return MusicLogFileStatus(
                fileURL: currentURL,
                byteCount: byteCount,
                maximumByteCount: maximumByteCount,
                isEnabled: enabled
            )
        }
    }

    func flush() {
        stateQueue.sync {
            ddLog?.flushLog()
        }
    }
}

private final class MusicFileLogger: NSObject, DDLogger {
    private let logger: DDFileLogger

    init(logFileManager: DDLogFileManagerDefault) {
        let logger = DDFileLogger(logFileManager: logFileManager)
        self.logger = logger
        super.init()
    }

    var logFormatter: (any DDLogFormatter)? {
        get { logger.logFormatter }
        set { logger.logFormatter = newValue }
    }

    var maximumFileSize: UInt64 {
        get { logger.maximumFileSize }
        set { logger.maximumFileSize = newValue }
    }

    var rollingFrequency: TimeInterval {
        get { logger.rollingFrequency }
        set { logger.rollingFrequency = newValue }
    }

    var maximumNumberOfLogFiles: UInt {
        get { logger.logFileManager.maximumNumberOfLogFiles }
        set { logger.logFileManager.maximumNumberOfLogFiles = newValue }
    }

    var logFilesDiskQuota: UInt64 {
        get { logger.logFileManager.logFilesDiskQuota }
        set { logger.logFileManager.logFilesDiskQuota = newValue }
    }

    var loggerQueue: DispatchQueue {
        logger.loggerQueue
    }

    func log(message: DDLogMessage) {
        logger.log(message: message)
    }

    func flush() {
        logger.flush()
    }

    func willRemove() {
        // DDFileLogger rolls the active file from its lifecycle callback.
        // Keep the active file in place when the application logger is
        // temporarily disabled; size-based rolling remains its only trigger.
        logger.flush()
    }

    var currentLogFileInfo: DDLogFileInfo? {
        logger.currentLogFileInfo
    }

    var logFileManager: any DDLogFileManager {
        logger.logFileManager
    }

    var loggerName: DDLoggerName {
        logger.loggerName
    }
}

private final class MusicLogFileManager: DDLogFileManagerDefault {
    private static let baseFileName = MusicLogger.fileName
    private static let baseFileStem = (baseFileName as NSString).deletingPathExtension

    override var newLogFileName: String {
        Self.baseFileName
    }

    override func isLogFile(withName fileName: String) -> Bool {
        guard fileName == Self.baseFileName || fileName.hasSuffix(".log") else {
            return false
        }
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.hasPrefix(Self.baseFileStem) else { return false }
        let suffix = String(stem.dropFirst(Self.baseFileStem.count))
        return suffix.isEmpty || (suffix.hasPrefix(" ") && Int(suffix.dropFirst()) != nil)
    }
}

private enum MusicLogLevel: String {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    var ddLevel: DDLogLevel {
        switch self {
        case .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .warning
        case .error, .fault: return .error
        }
    }

    var ddFlag: DDLogFlag {
        switch self {
        case .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .warning
        case .error, .fault: return .error
        }
    }

    var context: Int {
        switch self {
        case .debug: return 1
        case .info: return 2
        case .notice: return 3
        case .warning: return 4
        case .error: return 5
        case .fault: return 6
        }
    }
}

private final class MusicLogFileFormatter: NSObject, DDLogFormatter {
    private let dateFormatter = ISO8601DateFormatter()

    func format(message logMessage: DDLogMessage) -> String? {
        let level = MusicLogLevel(rawValue: levelRawValue(for: logMessage.context))?.rawValue
            ?? levelName(for: logMessage.flag)
        let category = (logMessage.representedObject as? String) ?? "unknown"
        let message = MusicLogSanitizer.redact(logMessage.message)
        return "\(dateFormatter.string(from: logMessage.timestamp)) [\(level)] [\(category)] \(message)"
    }

    private func levelRawValue(for context: Int) -> String {
        switch context {
        case 1: return MusicLogLevel.debug.rawValue
        case 2: return MusicLogLevel.info.rawValue
        case 3: return MusicLogLevel.notice.rawValue
        case 4: return MusicLogLevel.warning.rawValue
        case 5: return MusicLogLevel.error.rawValue
        case 6: return MusicLogLevel.fault.rawValue
        default: return ""
        }
    }

    private func levelName(for flag: DDLogFlag) -> String {
        switch flag {
        case .debug: return MusicLogLevel.debug.rawValue
        case .info: return MusicLogLevel.info.rawValue
        case .warning: return MusicLogLevel.warning.rawValue
        case .error: return MusicLogLevel.error.rawValue
        default: return MusicLogLevel.debug.rawValue
        }
    }
}

private enum MusicLogSanitizer {
    private static let sensitiveKeyPattern = try! NSRegularExpression(
        pattern: "(?i)(authorization|cookie|set-cookie|password|secret|api[_-]?key|token|session(?:id)?|synotoken)\\s*[:=]\\s*([^\\s,;]+)",
        options: []
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: "(?i)\\bBearer\\s+[^\\s,;]+",
        options: []
    )
    private static let urlCredentialPattern = try! NSRegularExpression(
        pattern: "(?i)(https?://[^\\s?#]+)(?:\\?[^\\s#]*)",
        options: []
    )
    private static let fileURLPattern = try! NSRegularExpression(
        pattern: "(?i)file://[^\\s,;]+",
        options: []
    )

    static func redact(_ message: String) -> String {
        var result = message
        result = replacing(
            sensitiveKeyPattern,
            in: result,
            with: "$1=<redacted>"
        )
        result = replacing(bearerPattern, in: result, with: "Bearer <redacted>")
        result = replacing(urlCredentialPattern, in: result, with: "$1?<redacted>")
        result = replacing(fileURLPattern, in: result, with: "file://<redacted>")
        return result
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
