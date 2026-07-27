import Foundation
import PGClonerCore
import PGClonerPostgres

actor CredentialBroker: DatabaseCredentialProvider {
    private let keychain = KeychainStore()
    private let azureCLI = AzureCLI()

    func password(for profile: ConnectionProfile) async throws -> String {
        switch profile.authentication {
        case .password:
            guard let password = try keychain.password(profileID: profile.id) else {
                throw CloneEngineError.missingPassword
            }
            return password
        case .azureCLI:
            return try await azureCLI.accessToken(customPath: profile.azureCLIPath)
        }
    }

    func save(password: String, for profile: ConnectionProfile) throws {
        try keychain.save(password: password, profileID: profile.id)
    }

    func delete(profileID: UUID) throws {
        try keychain.delete(profileID: profileID)
    }

    func hasPassword(profileID: UUID) -> Bool {
        (try? keychain.password(profileID: profileID)) != nil
    }
}
