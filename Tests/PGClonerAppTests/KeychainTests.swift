import Foundation
import Testing
@testable import PGClonerApp

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
}
