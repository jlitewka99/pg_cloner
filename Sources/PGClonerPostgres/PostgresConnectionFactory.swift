import Foundation
import Logging
import NIOSSL
import PGClonerCore
import PostgresNIO

public struct PostgresConnectionFactory: Sendable {
    private let logger: Logger

    public init(logger: Logger = Logger(label: "PGCloner.Postgres")) {
        self.logger = logger
    }

    public func connect(
        profile: ConnectionProfile,
        password: String,
        connectionID: Int
    ) async throws -> PostgresConnection {
        let tls = try makeTLS(mode: profile.tlsMode)
        var configuration = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            database: profile.database,
            tls: tls
        )
        configuration.options.connectTimeout = .seconds(20)
        configuration.options.tlsServerName = profile.host
        configuration.options.additionalStartupParameters = [
            ("application_name", "PG Cloner"),
            ("DateStyle", "ISO"),
            ("IntervalStyle", "postgres")
        ]

        do {
            return try await PostgresConnection.connect(
                configuration: configuration,
                id: connectionID,
                logger: logger
            )
        } catch {
            throw CloneEngineError.database(Self.safeMessage(error))
        }
    }

    func makeTLS(mode: TLSMode) throws -> PostgresConnection.Configuration.TLS {
        guard mode != .disable else { return .disable }

        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12

        switch mode {
        case .disable:
            return .disable
        case .prefer:
            configuration.certificateVerification = .fullVerification
            return .prefer(try NIOSSLContext(configuration: configuration))
        case .require:
            configuration.certificateVerification = .none
            return .require(try NIOSSLContext(configuration: configuration))
        case .verifyFull:
            configuration.certificateVerification = .fullVerification
            return .require(try NIOSSLContext(configuration: configuration))
        }
    }

    static func safeMessage(_ error: Error) -> String {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMessage = localized.isEmpty
            ? String(describing: type(of: error))
            : localized

        return [
            (#"(?i)(://[^:/\s]+:)[^@\s]+@"#, "$1<redacted>@"),
            (
                #"(?i)\b(password|token|access[_-]?token)\s*[:=]\s*[^,\s;]+"#,
                "$1=<redacted>"
            )
        ].reduce(rawMessage) { message, replacement in
            message.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }
}
