import Foundation
import PGClonerCore
import Testing
@testable import PGClonerPostgres

@Suite("Credential safety")
struct SecurityTests {
    @Test("Connection profile JSON never contains a password or token")
    func profileHasNoSecretFields() throws {
        let profile = ConnectionProfile(
            name: "Production",
            host: "database.example.com",
            database: "app",
            username: "cloner",
            authentication: .azureCLI,
            tlsMode: .verifyFull
        )

        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)

        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(!json.localizedCaseInsensitiveContains("token"))
        #expect(json.contains("database.example.com"))
    }

    @Test("Errors presented to the UI redact PostgreSQL credentials")
    func errorsAreRedacted() {
        let error = NSError(
            domain: "PG",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "postgres://alice:super-secret@database.example.com/app"
            ]
        )

        let message = PostgresConnectionFactory.safeMessage(error)

        #expect(!message.contains("super-secret"))
        #expect(message.contains("<redacted>"))
    }

    @Test("TLS modes map to disabled, optional, and enforced transports")
    func tlsModes() throws {
        let factory = PostgresConnectionFactory()
        let disabled = try factory.makeTLS(mode: .disable)
        let preferred = try factory.makeTLS(mode: .prefer)
        let required = try factory.makeTLS(mode: .require)
        let verified = try factory.makeTLS(mode: .verifyFull)

        #expect(!disabled.isAllowed)
        #expect(!disabled.isEnforced)
        #expect(preferred.isAllowed)
        #expect(!preferred.isEnforced)
        #expect(required.isAllowed)
        #expect(required.isEnforced)
        #expect(verified.isAllowed)
        #expect(verified.isEnforced)
    }
}
