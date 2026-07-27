import Foundation

public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case password
    case azureCLI
}

public enum TLSMode: String, Codable, CaseIterable, Sendable {
    case disable
    case prefer
    case require
    case verifyFull

    public var displayName: String {
        switch self {
        case .disable: "Disabled"
        case .prefer: "Prefer TLS"
        case .require: "Require TLS (no certificate verification)"
        case .verifyFull: "Verify certificate and hostname"
        }
    }
}

public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var authentication: AuthenticationMethod
    public var tlsMode: TLSMode
    public var azureCLIPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String = "localhost",
        port: Int = 5_432,
        database: String,
        username: String,
        authentication: AuthenticationMethod = .password,
        tlsMode: TLSMode = .disable,
        azureCLIPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.authentication = authentication
        self.tlsMode = tlsMode
        self.azureCLIPath = azureCLIPath
    }

    public var summary: String {
        "\(host):\(port)/\(database)"
    }
}

public struct TableReference: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var schema: String
    public var name: String

    public init(schema: String = "public", name: String) {
        self.schema = schema
        self.name = name
    }

    public init(qualifiedName: String) {
        let pieces = qualifiedName.split(separator: ".", maxSplits: 1).map(String.init)
        if pieces.count == 2 {
            self.init(schema: pieces[0], name: pieces[1])
        } else {
            self.init(name: pieces.first ?? qualifiedName)
        }
    }

    public var qualifiedName: String { "\(schema).\(name)" }
    public var description: String { qualifiedName }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.qualifiedName.localizedStandardCompare(rhs.qualifiedName) == .orderedAscending
    }
}

public struct TableSummary: Identifiable, Codable, Hashable, Sendable {
    public var reference: TableReference
    public var estimatedRows: Int64
    public var foreignKeyCount: Int

    public init(reference: TableReference, estimatedRows: Int64, foreignKeyCount: Int) {
        self.reference = reference
        self.estimatedRows = estimatedRows
        self.foreignKeyCount = foreignKeyCount
    }

    public var id: String { reference.qualifiedName }
}

public enum IdentityGeneration: String, Codable, Sendable {
    case always
    case byDefault
}

public struct ColumnMetadata: Codable, Hashable, Sendable {
    public var name: String
    public var typeName: String
    public var isNullable: Bool
    public var defaultExpression: String?
    public var generatedExpression: String?
    public var identity: IdentityGeneration?

    public init(
        name: String,
        typeName: String,
        isNullable: Bool,
        defaultExpression: String? = nil,
        generatedExpression: String? = nil,
        identity: IdentityGeneration? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.generatedExpression = generatedExpression
        self.identity = identity
    }

    public var isGenerated: Bool { generatedExpression != nil }
}

public struct PrimaryKeyMetadata: Codable, Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var definition: String

    public init(name: String, columns: [String], definition: String) {
        self.name = name
        self.columns = columns
        self.definition = definition
    }
}

public struct ForeignKeyMetadata: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var childTable: TableReference
    public var parentTable: TableReference
    public var childColumns: [String]
    public var parentColumns: [String]
    public var definition: String?

    public init(
        name: String,
        childTable: TableReference,
        parentTable: TableReference,
        childColumns: [String],
        parentColumns: [String],
        definition: String? = nil
    ) {
        self.name = name
        self.childTable = childTable
        self.parentTable = parentTable
        self.childColumns = childColumns
        self.parentColumns = parentColumns
        self.definition = definition
    }

    public var id: String { "\(childTable.qualifiedName).\(name)" }
}

public struct IndexMetadata: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var definition: String

    public init(name: String, definition: String) {
        self.name = name
        self.definition = definition
    }

    public var id: String { name }
}

public struct SequenceMetadata: Codable, Hashable, Sendable {
    public var column: String
    public var qualifiedSequenceName: String

    public init(column: String, qualifiedSequenceName: String) {
        self.column = column
        self.qualifiedSequenceName = qualifiedSequenceName
    }
}

public struct TableMetadata: Codable, Hashable, Sendable {
    public var reference: TableReference
    public var columns: [ColumnMetadata]
    public var primaryKey: PrimaryKeyMetadata?
    public var foreignKeys: [ForeignKeyMetadata]
    public var indexes: [IndexMetadata]
    public var sequences: [SequenceMetadata]

    public init(
        reference: TableReference,
        columns: [ColumnMetadata],
        primaryKey: PrimaryKeyMetadata? = nil,
        foreignKeys: [ForeignKeyMetadata] = [],
        indexes: [IndexMetadata] = [],
        sequences: [SequenceMetadata] = []
    ) {
        self.reference = reference
        self.columns = columns
        self.primaryKey = primaryKey
        self.foreignKeys = foreignKeys
        self.indexes = indexes
        self.sequences = sequences
    }

    public var copyableColumns: [ColumnMetadata] {
        columns.filter { !$0.isGenerated }
    }
}

public enum ConflictMode: String, Codable, CaseIterable, Sendable {
    case error
    case replace
}

public enum TransformationKind: String, Codable, CaseIterable, Sendable {
    case rot13 = "ROT13"
    case reverse = "Reverse"
    case add100 = "Add100"
}

public struct CopyOptions: Codable, Hashable, Sendable {
    public var limit: Int?
    public var whereClause: String?
    public var requireFilter: Bool
    public var skipStructure: Bool
    public var conflictMode: ConflictMode
    public var transformations: [String: TransformationKind]

    public init(
        limit: Int? = nil,
        whereClause: String? = nil,
        requireFilter: Bool = true,
        skipStructure: Bool = false,
        conflictMode: ConflictMode = .error,
        transformations: [String: TransformationKind] = [:]
    ) {
        self.limit = limit
        self.whereClause = whereClause?.nilIfBlank
        self.requireFilter = requireFilter
        self.skipStructure = skipStructure
        self.conflictMode = conflictMode
        self.transformations = transformations
    }

    public func validated() throws -> Self {
        if let limit, limit <= 0 {
            throw CloneEngineError.invalidLimit
        }
        if requireFilter, limit == nil, whereClause.nilIfBlank == nil {
            throw CloneEngineError.filterRequired
        }
        return self
    }
}

public struct TableCopyOptions: Codable, Hashable, Sendable {
    public var limit: Int?
    public var whereClause: String?

    public init(limit: Int? = nil, whereClause: String? = nil) {
        self.limit = limit
        self.whereClause = whereClause?.nilIfBlank
    }
}

public struct TableFilter: Codable, Hashable, Sendable {
    public var limit: Int?
    public var whereClause: String?

    public init(limit: Int? = nil, whereClause: String? = nil) {
        self.limit = limit
        self.whereClause = whereClause?.nilIfBlank
    }
}

public struct CloneRequest: Codable, Hashable, Sendable {
    public var sourceProfileID: UUID
    public var targetProfileID: UUID
    public var selectedTables: [TableReference]
    public var options: CopyOptions
    public var perTableOptions: [TableReference: TableCopyOptions]

    public init(
        sourceProfileID: UUID,
        targetProfileID: UUID,
        selectedTables: [TableReference],
        options: CopyOptions,
        perTableOptions: [TableReference: TableCopyOptions] = [:]
    ) {
        self.sourceProfileID = sourceProfileID
        self.targetProfileID = targetProfileID
        self.selectedTables = selectedTables
        self.options = options
        self.perTableOptions = perTableOptions
    }
}

public struct ClonePlan: Codable, Hashable, Sendable {
    public var selected: [TableReference]
    public var required: [TableReference]
    public var ordered: [TableReference]
    public var cyclicTables: Set<TableReference>

    public init(
        selected: [TableReference],
        required: [TableReference],
        ordered: [TableReference],
        cyclicTables: Set<TableReference> = []
    ) {
        self.selected = selected
        self.required = required
        self.ordered = ordered
        self.cyclicTables = cyclicTables
    }

    public var containsCycle: Bool { !cyclicTables.isEmpty }
}

public enum ClonePhase: String, Codable, Sendable {
    case preflight
    case creatingStructure
    case counting
    case copying
    case synchronizingSequence
    case creatingIndexes
    case creatingForeignKeys
    case completed
    case failed
    case cancelled
}

public struct TableProgress: Codable, Hashable, Sendable {
    public var table: TableReference
    public var phase: ClonePhase
    public var rowsCopied: Int64
    public var rowsTotal: Int64?

    public init(
        table: TableReference,
        phase: ClonePhase,
        rowsCopied: Int64 = 0,
        rowsTotal: Int64? = nil
    ) {
        self.table = table
        self.phase = phase
        self.rowsCopied = rowsCopied
        self.rowsTotal = rowsTotal
    }

    public var fractionCompleted: Double? {
        guard let rowsTotal, rowsTotal > 0 else { return nil }
        return min(1, Double(rowsCopied) / Double(rowsTotal))
    }
}

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
    case success
}

public struct CloneLogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: LogLevel
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public enum CloneEvent: Sendable {
    case started(ClonePlan)
    case progress(TableProgress)
    case log(CloneLogEntry)
    case finished(CloneResult)
}

public enum TableCloneOutcome: Codable, Hashable, Sendable {
    case completed(rows: Int64)
    case failed(message: String)
    case rolledBack(message: String)
    case skipped(reason: String)
}

public struct CloneResult: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var outcomes: [TableReference: TableCloneOutcome]
    public var wasCancelled: Bool

    public init(
        startedAt: Date,
        finishedAt: Date = Date(),
        outcomes: [TableReference: TableCloneOutcome],
        wasCancelled: Bool = false
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.wasCancelled = wasCancelled
    }

    public var isCompleteSuccess: Bool {
        !wasCancelled && !outcomes.isEmpty && outcomes.values.allSatisfy {
            if case .completed = $0 { return true }
            return false
        }
    }
}

public enum CloneEngineError: LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case filterRequired
    case invalidLimit
    case noTablesSelected
    case profileNotFound
    case missingPassword
    case sameSourceAndTarget
    case insufficientPrivileges([String])
    case incompatibleTarget([String])
    case destructiveDependencies([String])
    case unsupportedTypes([String])
    case missingPrimaryKey(TableReference)
    case azureCLINotFound
    case azureCLI(String)
    case invalidMetadata(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A clone is already running."
        case .notRunning: "No clone is running."
        case .filterRequired: "Specify a LIMIT or WHERE filter before cloning."
        case .invalidLimit: "LIMIT must be a positive integer."
        case .noTablesSelected: "Select at least one table."
        case .profileNotFound: "The selected connection profile no longer exists."
        case .missingPassword: "No password is stored for this connection."
        case .sameSourceAndTarget:
            "Source and target resolve to the same database. Cloning in place is blocked."
        case let .insufficientPrivileges(objects):
            "Required database privileges are missing: \(objects.joined(separator: ", "))."
        case let .incompatibleTarget(problems):
            "The target is not compatible with the clone plan: \(problems.joined(separator: " "))."
        case let .destructiveDependencies(objects):
            "The clone would remove objects outside the plan: \(objects.joined(separator: ", "))."
        case let .unsupportedTypes(types):
            "Required PostgreSQL types are missing on the target: \(types.joined(separator: ", "))."
        case let .missingPrimaryKey(table):
            "Replace mode requires a primary key on \(table.qualifiedName)."
        case .azureCLINotFound:
            "Azure CLI was not found. Install it or select the az executable in Settings."
        case let .azureCLI(message): "Azure CLI failed: \(message)"
        case let .invalidMetadata(message): "Invalid PostgreSQL metadata: \(message)"
        case let .database(message): message
        }
    }
}

extension Optional where Wrapped == String {
    public var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension String {
    public var nilIfBlank: String? {
        Optional(self).nilIfBlank
    }
}
