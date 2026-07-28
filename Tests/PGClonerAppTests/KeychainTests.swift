import Foundation
import Testing
@testable import PGClonerApp
import PGClonerCore

@Suite("macOS Keychain")
struct KeychainTests {
    @Test("Password round-trips and can be deleted")
    func passwordLifecycle() throws {
        let store = KeychainStore()
        let profileID = UUID()
        let secret = "pgcloner-test-\(UUID().uuidString)"
        defer { try? store.delete(profileID: profileID) }

        try store.save(password: secret, profileID: profileID)
        #expect(try store.password(profileID: profileID) == secret)
        try store.delete(profileID: profileID)
        #expect(try store.password(profileID: profileID) == nil)
    }

    @Test("Stored passwords can be copied to a role-specific profile")
    func copyPasswordForMigratedProfile() async throws {
        let broker = CredentialBroker()
        let originalID = UUID()
        let copiedID = UUID()
        let original = ConnectionProfile(
            id: originalID,
            name: "Original",
            database: "postgres",
            username: "postgres"
        )
        let copied = ConnectionProfile(
            id: copiedID,
            name: "Copied",
            database: "postgres",
            username: "postgres"
        )
        let password = "pgcloner-test-\(UUID().uuidString)"
        defer {
            try? KeychainStore().delete(profileID: originalID)
            try? KeychainStore().delete(profileID: copiedID)
        }

        try await broker.save(password: password, for: original)
        try await broker.copyStoredPassword(from: originalID, to: copiedID)

        #expect(try KeychainStore().password(profileID: copied.id) == password)
    }
}
