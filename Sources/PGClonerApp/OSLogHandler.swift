import Logging
import OSLog

struct PGClonerOSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    private let systemLog: OSLog

    init(label: String) {
        systemLog = OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "com.pgcloner.app",
            category: label
        )
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= logLevel else { return }
        // Database errors are redacted before reaching Logging. Metadata is
        // deliberately omitted because dependencies may attach connection data.
        let value = event.message.description
        let type: OSLogType
        switch event.level {
        case .trace, .debug:
            type = .debug
        case .info, .notice:
            type = .info
        case .warning:
            type = .default
        case .error:
            type = .error
        case .critical:
            type = .fault
        }
        os_log("%{public}@", log: systemLog, type: type, value)
    }
}
