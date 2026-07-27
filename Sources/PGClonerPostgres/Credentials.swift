import Foundation
import PGClonerCore

public protocol DatabaseCredentialProvider: Sendable {
    func password(for profile: ConnectionProfile) async throws -> String
}

public struct ClosureCredentialProvider: DatabaseCredentialProvider {
    private let resolver: @Sendable (ConnectionProfile) async throws -> String

    public init(_ resolver: @escaping @Sendable (ConnectionProfile) async throws -> String) {
        self.resolver = resolver
    }

    public func password(for profile: ConnectionProfile) async throws -> String {
        try await resolver(profile)
    }
}
