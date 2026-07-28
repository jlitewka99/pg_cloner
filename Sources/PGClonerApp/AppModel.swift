import Combine
import Foundation
import Observation
import PGClonerCore
import PGClonerPostgres

struct TableFilterDraft: Hashable {
    var limit = ""
    var whereClause = ""
}

private final class EventTaskStorage {
    var task: Task<Void, Never>?
}

@MainActor
#if PGCLONER_OBSERVATION_MACRO
@Observable
#endif
final class AppModel: ObservableObject {
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var sourceProfiles: [ConnectionProfile] = []
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var targetProfiles: [ConnectionProfile] = []
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var sourceProfileID: UUID?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var targetProfileID: UUID?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var schemas: [String] = []
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var selectedSchema = "public"
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var tables: [TableSummary] = []
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var tableSearch = ""
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var selectedTables = Set<TableReference>()
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var plan: ClonePlan?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var tableFilters: [TableReference: TableFilterDraft] = [:]

    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var limit = ""
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var whereClause = ""
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var requireFilter = true
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var skipStructure = false
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var conflictMode: ConflictMode = .error
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var activeTransformations: [String: TransformationKind] = [:]

    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var progress: [TableReference: TableProgress] = [:]
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var logs: [CloneLogEntry] = []
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var result: CloneResult?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var isLoadingSource = false
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var isCloning = false
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var errorMessage: String?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var successMessage: String?
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var showDestructiveConfirmation = false

    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var defaultRules = TransformationRuleSet()
    #if !PGCLONER_OBSERVATION_MACRO
    @Published
    #endif
    var localRules = TransformationRuleSet(description: "Local transformation overrides")
  #if !PGCLONER_OBSERVATION_MACRO
    @Published
  #endif
  var executionOptions = CloneExecutionOptions()

    let profileStore: ProfileStore
    let credentials: CredentialBroker
    private let rules: RuleStore
  private let cloneSettings: CloneSettingsStore
    private let coordinator: CloneCoordinator
    private let eventTaskStorage = EventTaskStorage()

    init() {
        let profileStore = ProfileStore()
        let credentials = CredentialBroker()
        self.profileStore = profileStore
        self.credentials = credentials
        self.rules = RuleStore(profileStore: profileStore)
    self.cloneSettings = CloneSettingsStore(profileStore: profileStore)
        self.coordinator = CloneCoordinator(credentials: credentials)
    }

    var sourceProfile: ConnectionProfile? {
        sourceProfiles.first { $0.id == sourceProfileID }
    }

    var targetProfile: ConnectionProfile? {
        targetProfiles.first { $0.id == targetProfileID }
    }

    var filteredTables: [TableSummary] {
        guard let search = tableSearch.nilIfBlank?.lowercased() else { return tables }
        return tables.filter { $0.reference.name.lowercased().contains(search) }
    }

    var canClone: Bool {
        sourceProfile != nil
            && targetProfile != nil
            && !selectedTables.isEmpty
            && !isCloning
    }

    func bootstrap() async {
        do {
            sourceProfiles = try await profileStore.load(.source)
            targetProfiles = try await profileStore.load(.target)
            sourceProfileID = nil
            targetProfileID = nil

            let ruleSets = try await rules.load()
            defaultRules = ruleSets.defaults
            localRules = ruleSets.local
      executionOptions = try await cloneSettings.load()

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveProfile(
        _ profile: ConnectionProfile,
        for role: ConnectionProfileRole,
        password: String
    ) async throws {
        if profile.authentication == .password, let password = password.nilIfBlank {
            try await credentials.save(password: password, for: profile)
        }
        switch role {
        case .source:
            upsert(profile, in: &sourceProfiles)
            try await profileStore.save(sourceProfiles, for: .source)
            sourceProfileID = sourceProfileID ?? profile.id
        case .target:
            upsert(profile, in: &targetProfiles)
            try await profileStore.save(targetProfiles, for: .target)
            targetProfileID = targetProfileID ?? profile.id
        }
    }

    func deleteProfile(_ profile: ConnectionProfile, from role: ConnectionProfileRole) async {
        do {
            try await profileStore.delete(profileID: profile.id, from: role)
            try await credentials.delete(profileID: profile.id)
            switch role {
            case .source:
                sourceProfiles.removeAll { $0.id == profile.id }
                if sourceProfileID == profile.id {
                    sourceProfileID = sourceProfiles.first?.id
                    sourceChanged()
                }
            case .target:
                targetProfiles.removeAll { $0.id == profile.id }
                if targetProfileID == profile.id {
                    targetProfileID = targetProfiles.first?.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsert(_ profile: ConnectionProfile, in profiles: inout [ConnectionProfile]) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func testProfile(_ profile: ConnectionProfile) async throws -> String {
        try await coordinator.testConnection(profile)
    }

    func sourceChanged() {
        selectedTables.removeAll()
        plan = nil
        activeTransformations = [:]
        guard sourceProfile != nil else {
            schemas = []
            tables = []
            return
        }
        Task { await loadSource() }
    }

    func loadSource() async {
        guard let sourceProfile else { return }
        isLoadingSource = true
        defer { isLoadingSource = false }
        do {
            schemas = try await coordinator.schemas(source: sourceProfile)
            if !schemas.contains(selectedSchema) {
                selectedSchema = schemas.first ?? "public"
            }
            await loadTables()
        } catch {
            tables = []
            errorMessage = error.localizedDescription
        }
    }

    func loadTables() async {
        guard let sourceProfile else { return }
        isLoadingSource = true
        defer { isLoadingSource = false }
        do {
            tables = try await coordinator.tables(
                source: sourceProfile,
                schema: selectedSchema
            )
            selectedTables = selectedTables.filter { $0.schema == selectedSchema }
            await refreshPlan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ table: TableReference) {
        if selectedTables.contains(table) {
            selectedTables.remove(table)
            tableFilters.removeValue(forKey: table)
        } else {
            selectedTables.insert(table)
        }
        Task { await refreshPlan() }
    }

    func refreshPlan() async {
        guard let sourceProfile, !selectedTables.isEmpty else {
            plan = nil
            activeTransformations = [:]
            return
        }
        do {
            plan = try await coordinator.plan(
                source: sourceProfile,
                selectedTables: selectedTables.sorted()
            )
            let mergedRules = localRules.merged(over: defaultRules)
            activeTransformations = try await coordinator.suggestedTransformations(
                source: sourceProfile,
                tables: selectedTables.sorted(),
                rules: mergedRules
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestClone() {
        guard canClone else { return }
        if !skipStructure {
            showDestructiveConfirmation = true
        } else {
            startClone()
        }
    }

    func startClone() {
        showDestructiveConfirmation = false
        guard let sourceProfile, let targetProfile else { return }

        do {
            let parsedLimit: Int?
            if let text = limit.nilIfBlank {
                guard let value = Int(text), value > 0 else {
                    throw CloneEngineError.invalidLimit
                }
                parsedLimit = value
            } else {
                parsedLimit = nil
            }

      let perTable = try Dictionary(
        uniqueKeysWithValues: tableFilters.map {
                table, draft in
                let tableLimit: Int?
                if let value = draft.limit.nilIfBlank {
                    guard let parsed = Int(value), parsed > 0 else {
                        throw CloneEngineError.invalidLimit
                    }
                    tableLimit = parsed
                } else {
                    tableLimit = nil
                }
                return (
                    table,
                    TableCopyOptions(
                        limit: tableLimit,
                        whereClause: draft.whereClause
                    )
                )
            })

            let options = try CopyOptions(
                limit: parsedLimit,
                whereClause: whereClause,
                requireFilter: requireFilter,
                skipStructure: skipStructure,
                conflictMode: conflictMode,
                transformations: activeTransformations
            ).validated()

            let request = CloneRequest(
                sourceProfileID: sourceProfile.id,
                targetProfileID: targetProfile.id,
                selectedTables: selectedTables.sorted(),
                options: options,
        perTableOptions: perTable,
        executionOptions: try executionOptions.validated()
            )

            progress = [:]
            result = nil
            errorMessage = nil
            successMessage = nil
            isCloning = true

            eventTaskStorage.task?.cancel()
            eventTaskStorage.task = Task {
                do {
                    let stream = try await coordinator.start(
                        request: request,
                        sourceProfile: sourceProfile,
                        targetProfile: targetProfile
                    )
                    for await event in stream {
                        handle(event)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    isCloning = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelClone() {
        Task { await coordinator.cancel() }
    }

    func resetSession() {
        selectedTables.removeAll()
        tableFilters.removeAll()
        plan = nil
        progress.removeAll()
        logs.removeAll()
        result = nil
        errorMessage = nil
        successMessage = nil
    }

    func saveLocalRules() async {
        do {
            try await rules.save(localRules)
            successMessage = "Transformation rules saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

  func saveExecutionOptions() async {
    do {
      executionOptions = try executionOptions.validated()
      try await cloneSettings.save(executionOptions)
      successMessage = "Execution settings saved."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

    private func handle(_ event: CloneEvent) {
        switch event {
    case .started(let plan):
            self.plan = plan
    case .progress(let value):
            progress[value.table] = value
    case .log(let entry):
            logs.append(entry)
            if logs.count > 500 {
                logs.removeFirst(logs.count - 500)
            }
    case .finished(let result):
            self.result = result
            isCloning = false
            if result.isCompleteSuccess {
                successMessage = "Clone completed successfully."
            } else if result.wasCancelled {
                errorMessage = "Clone cancelled. Completed tables were preserved."
            } else {
                errorMessage = "Clone finished with a partial result. Review the log."
            }
        }
    }

    private func appendLog(_ level: LogLevel, _ message: String) {
        logs.append(CloneLogEntry(level: level, message: message))
    }
}
