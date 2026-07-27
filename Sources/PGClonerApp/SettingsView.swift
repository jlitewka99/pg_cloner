import PGClonerCore
import SwiftUI

struct SettingsView: View {
    #if PGCLONER_OBSERVATION_MACRO
    @Bindable var model: AppModel
    #else
    @ObservedObject var model: AppModel
    #endif

    var body: some View {
        TabView {
            ConnectionSettingsView(model: model)
                .tabItem {
                    Label("Connections", systemImage: "externaldrive.connected.to.line.below")
                }

            RuleSettingsView(model: model)
                .tabItem {
                    Label("Transformations", systemImage: "wand.and.stars")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding()
    }
}

private struct ConnectionSettingsView: View {
    #if PGCLONER_OBSERVATION_MACRO
    @Bindable var model: AppModel
    #else
    @ObservedObject var model: AppModel
    #endif
    @State private var editingProfile: ConnectionProfile?
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Connection profiles")
                    .font(.title2.bold())
                Spacer()
                Button {
                    editingProfile = nil
                    showingEditor = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("addConnectionButton")
            }

            List {
                ForEach(model.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.name).font(.headline)
                            Text(profile.summary)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(profile.authentication == .azureCLI ? "Azure CLI" : "Password")
                            .foregroundStyle(.secondary)
                        Button("Edit") {
                            editingProfile = profile
                            showingEditor = true
                        }
                        Button(role: .destructive) {
                            Task { await model.deleteProfile(profile) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .overlay {
                if model.profiles.isEmpty {
                    ContentUnavailableView(
                        "No profiles",
                        systemImage: "externaldrive.badge.plus"
                    )
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(model: model, profile: editingProfile)
        }
    }
}

private struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let existingID: UUID

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var database: String
    @State private var username: String
    @State private var password = ""
    @State private var authentication: AuthenticationMethod
    @State private var tlsMode: TLSMode
    @State private var azureCLIPath: String
    @State private var status: String?
    @State private var isWorking = false

    init(model: AppModel, profile: ConnectionProfile?) {
        self.model = model
        existingID = profile?.id ?? UUID()
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "localhost")
        _port = State(initialValue: String(profile?.port ?? 5_432))
        _database = State(initialValue: profile?.database ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _authentication = State(initialValue: profile?.authentication ?? .password)
        _tlsMode = State(initialValue: profile?.tlsMode ?? .disable)
        _azureCLIPath = State(initialValue: profile?.azureCLIPath ?? "")
    }

    private var profile: ConnectionProfile? {
        guard let parsedPort = Int(port), parsedPort > 0, parsedPort <= 65_535 else {
            return nil
        }
        guard name.nilIfBlank != nil,
              host.nilIfBlank != nil,
              database.nilIfBlank != nil,
              username.nilIfBlank != nil
        else {
            return nil
        }
        return ConnectionProfile(
            id: existingID,
            name: name,
            host: host,
            port: parsedPort,
            database: database,
            username: username,
            authentication: authentication,
            tlsMode: tlsMode,
            azureCLIPath: azureCLIPath.nilIfBlank
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection profile")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("profileName")
                TextField("Host", text: $host)
                    .accessibilityIdentifier("profileHost")
                TextField("Port", text: $port)
                    .accessibilityIdentifier("profilePort")
                TextField("Database", text: $database)
                    .accessibilityIdentifier("profileDatabase")
                TextField("Username", text: $username)
                    .accessibilityIdentifier("profileUsername")

                Picker("Authentication", selection: $authentication) {
                    Text("Password").tag(AuthenticationMethod.password)
                    Text("Azure CLI").tag(AuthenticationMethod.azureCLI)
                }

                if authentication == .password {
                    SecureField("Password (leave blank to keep)", text: $password)
                        .accessibilityIdentifier("profilePassword")
                } else {
                    TextField("Custom az path (optional)", text: $azureCLIPath)
                    Text("The token is fetched immediately before connecting and is never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("TLS", selection: $tlsMode) {
                    ForEach(TLSMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            .formStyle(.grouped)

            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(status.hasPrefix("Connected") ? .green : .red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save and test") {
                    guard let profile else { return }
                    isWorking = true
                    Task {
                        do {
                            try await model.saveProfile(profile, password: password)
                            let version = try await model.testProfile(profile)
                            status = "Connected: \(version)"
                        } catch {
                            status = error.localizedDescription
                        }
                        isWorking = false
                    }
                }
                .disabled(profile == nil || isWorking)
                Button("Save") {
                    guard let profile else { return }
                    isWorking = true
                    Task {
                        do {
                            try await model.saveProfile(profile, password: password)
                            dismiss()
                        } catch {
                            status = error.localizedDescription
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile == nil || isWorking)
                .accessibilityIdentifier("saveProfileButton")
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
    }
}

private struct RuleSettingsView: View {
    #if PGCLONER_OBSERVATION_MACRO
    @Bindable var model: AppModel
    #else
    @ObservedObject var model: AppModel
    #endif
    @State private var pattern = ""
    @State private var strategy: TransformationKind = .rot13
    @State private var ruleDescription = ""
    @State private var excludePattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Local transformation rules")
                        .font(.title2.bold())
                    Text("Local rules override the bundled defaults.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") {
                    Task { await model.saveLocalRules() }
                }
                .buttonStyle(.borderedProminent)
            }

            GroupBox("Column patterns") {
                List {
                    ForEach(
                        Array(model.localRules.columnPatterns.enumerated()),
                        id: \.offset
                    ) { index, rule in
                        HStack {
                            Text(rule.pattern)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(rule.strategy.rawValue)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                model.localRules.columnPatterns.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .frame(minHeight: 150)

                HStack {
                    TextField("Regular expression", text: $pattern)
                    Picker("Strategy", selection: $strategy) {
                        ForEach(TransformationKind.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    TextField("Description", text: $ruleDescription)
                    Button("Add") {
                        guard let value = pattern.nilIfBlank else { return }
                        model.localRules.columnPatterns.append(
                            .init(
                                pattern: value,
                                strategy: strategy,
                                description: ruleDescription
                            )
                        )
                        pattern = ""
                        ruleDescription = ""
                    }
                    .disabled(pattern.nilIfBlank == nil)
                }
            }

            GroupBox("Excluded columns") {
                List {
                    ForEach(model.localRules.excludePatterns, id: \.self) { value in
                        HStack {
                            Text(value).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                model.localRules.excludePatterns.removeAll { $0 == value }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .frame(minHeight: 100)

                HStack {
                    TextField("Regular expression", text: $excludePattern)
                    Button("Add") {
                        guard let value = excludePattern.nilIfBlank else { return }
                        model.localRules.excludePatterns.append(value)
                        excludePattern = ""
                    }
                    .disabled(excludePattern.nilIfBlank == nil)
                }
            }
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("PG Cloner").font(.largeTitle.bold())
            Text("Native PostgreSQL subset cloning for macOS")
                .foregroundStyle(.secondary)
            Text("PostgreSQL → PostgreSQL • macOS 14+ • Universal 2")
                .font(.caption)
            Spacer()
            Text(
                "Passwords are stored in Keychain. Azure tokens are fetched on demand "
                    + "and are not persisted."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(50)
    }
}
