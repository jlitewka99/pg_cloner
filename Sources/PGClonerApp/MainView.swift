import PGClonerCore
import SwiftUI

struct MainView: View {
    #if PGCLONER_OBSERVATION_MACRO
    @Bindable var model: AppModel
    #else
    @ObservedObject var model: AppModel
    #endif

    var body: some View {
        NavigationSplitView {
            tablesColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            cloneColumn
                .navigationSplitViewColumnWidth(min: 480, ideal: 600)
        }
        .navigationTitle("PG Cloner")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    connectionToolbarPicker(
                        title: "Source",
                        selection: $model.sourceProfileID,
                        accessibilityIdentifier: "sourceConnectionPicker"
                    )
                    .onChange(of: model.sourceProfileID) {
                        model.sourceChanged()
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    connectionToolbarPicker(
                        title: "Target",
                        selection: $model.targetProfileID,
                        accessibilityIdentifier: "targetConnectionPicker"
                    )
                }
                .disabled(model.isCloning)
                // The principal toolbar item clips its content to the rounded
                // toolbar group. Keep the labels clear of its leading edge.
                .padding(.horizontal, 12)
            }

            ToolbarItemGroup {
                if model.isCloning {
                    ProgressView()
                        .controlSize(.small)
                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settingsButton")
                Button {
                    model.resetSession()
                } label: {
                    Label("Reset Session", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isCloning)
            }
        }
        .alert("Destructive clone", isPresented: $model.showDestructiveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Drop and clone", role: .destructive) {
                model.startClone()
            }
        } message: {
            Text(
                "Existing target tables in the plan will be dropped and recreated. "
                    + "Objects outside the plan are checked during preflight."
            )
        }
        .alert(
            "PG Cloner",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .safeAreaInset(edge: .top) {
            if let message = model.successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                    Spacer()
                    Button("Dismiss") { model.successMessage = nil }
                        .buttonStyle(.plain)
                }
                .padding(10)
                .background(.green.opacity(0.12))
            }
        }
    }

    private func connectionToolbarPicker(
        title: String,
        selection: Binding<UUID?>,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                Text("Select connection").tag(nil as UUID?)
                ForEach(model.profiles) { profile in
                    Text("\(profile.name) · \(profile.database)")
                        .tag(profile.id as UUID?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var tablesColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Schema", selection: $model.selectedSchema) {
                    ForEach(model.schemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
                .accessibilityIdentifier("schemaPicker")
                .onChange(of: model.selectedSchema) {
                    Task { await model.loadTables() }
                }
                if model.isLoadingSource {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()

            TextField("Filter tables", text: $model.tableSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if model.tables.isEmpty, !model.isLoadingSource {
                ContentUnavailableView(
                    "No tables",
                    systemImage: "tablecells",
                    description: Text("Select a source connection and schema.")
                )
            } else {
                List(model.filteredTables) { table in
                    Button {
                        model.toggle(table.reference)
                    } label: {
                        HStack {
                            Image(
                                systemName: model.selectedTables.contains(table.reference)
                                    ? "checkmark.square.fill"
                                    : "square"
                            )
                            .foregroundStyle(
                                model.selectedTables.contains(table.reference)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(table.reference.name)
                                HStack(spacing: 8) {
                                    Text(table.estimatedRows.formatted())
                                    if table.foreignKeyCount > 0 {
                                        Text("FK \(table.foreignKeyCount)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("table.\(table.reference.qualifiedName)")
                }
            }

            Divider()
            Text("\(model.selectedTables.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private var cloneColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                copyOptions
                Divider()
                clonePlan
                if !model.activeTransformations.isEmpty {
                    Divider()
                    transformations
                }
                Divider()
                actionBar
                if let result = model.result {
                    Divider()
                    resultView(result)
                }
                if !model.logs.isEmpty {
                    Divider()
                    logView
                }
            }
            .padding()
        }
    }

    private var copyOptions: some View {
        GroupBox("Copy options") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("LIMIT")
                    TextField("e.g. 1000", text: $model.limit)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("WHERE")
                    TextField("e.g. created_at > now() - interval '7 days'", text: $model.whereClause)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Conflicts")
                    Picker("Conflicts", selection: $model.conflictMode) {
                        Text("Stop with error").tag(ConflictMode.error)
                        Text("Replace (upsert)").tag(ConflictMode.replace)
                    }
                    .labelsHidden()
                }
            }

            Toggle("Require LIMIT or WHERE", isOn: $model.requireFilter)
            Toggle("Data only — keep existing target structure", isOn: $model.skipStructure)
        }
    }

    @ViewBuilder
    private var clonePlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clone plan")
                    .font(.headline)
                Spacer()
                if let plan = model.plan {
                    Text("\(plan.ordered.count) tables")
                        .foregroundStyle(.secondary)
                }
            }

            if let plan = model.plan {
                if plan.containsCycle {
                    Label(
                        "Foreign-key cycle detected. Full parent copies may be required.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }

                ForEach(Array(plan.ordered.enumerated()), id: \.element) { index, table in
                    PlanTableRow(
                        index: index + 1,
                        table: table,
                        selected: plan.selected.contains(table),
                        progress: model.progress[table],
                        draft: Binding(
                            get: { model.tableFilters[table] ?? TableFilterDraft() },
                            set: { model.tableFilters[table] = $0 }
                        )
                    )
                }
            } else {
                ContentUnavailableView(
                    "Select tables",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Required parent tables and clone order appear here.")
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var transformations: some View {
        DisclosureGroup("Transformations (\(model.activeTransformations.count))") {
            ForEach(model.activeTransformations.keys.sorted(), id: \.self) { column in
                HStack {
                    Text(column).font(.system(.body, design: .monospaced))
                    Spacer()
                    Picker(
                        "Strategy",
                        selection: Binding(
                            get: { model.activeTransformations[column] ?? .rot13 },
                            set: { model.activeTransformations[column] = $0 }
                        )
                    ) {
                        ForEach(TransformationKind.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Button {
                        model.activeTransformations.removeValue(forKey: column)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Disable for this clone")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            if model.isCloning {
                Button("Cancel clone", role: .destructive) {
                    model.cancelClone()
                }
                .accessibilityIdentifier("cancelCloneButton")
                Spacer()
                Text("Clone in progress…")
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Button {
                    model.requestClone()
                } label: {
                    Label("Clone \(model.plan?.ordered.count ?? 0) tables", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canClone)
                .accessibilityIdentifier("cloneButton")
            }
        }
    }

    private var logView: some View {
        DisclosureGroup("Log (\(model.logs.count))", isExpanded: .constant(true)) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(model.logs.suffix(100)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .foregroundStyle(logColor(entry.level))
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func resultView(_ result: CloneResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(result.outcomes.keys.sorted(), id: \.self) { table in
                    HStack(alignment: .firstTextBaseline) {
                        Text(table.qualifiedName)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        if let outcome = result.outcomes[table] {
                            Label {
                                Text(outcomeText(outcome))
                            } icon: {
                                Image(systemName: outcomeIcon(outcome))
                            }
                            .font(.caption)
                            .foregroundStyle(outcomeColor(outcome))
                        }
                    }
                }
            }
        } label: {
            Label(
                result.isCompleteSuccess ? "Completed" : "Partial result",
                systemImage: result.isCompleteSuccess
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
        }
    }

    private func outcomeText(_ outcome: TableCloneOutcome) -> String {
        switch outcome {
        case let .completed(rows): "\(rows.formatted()) rows"
        case let .failed(message): "Failed: \(message)"
        case let .rolledBack(message): "Rolled back: \(message)"
        case let .skipped(reason): "Skipped: \(reason)"
        }
    }

    private func outcomeIcon(_ outcome: TableCloneOutcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .rolledBack: "arrow.uturn.backward.circle.fill"
        case .skipped: "forward.end.circle.fill"
        }
    }

    private func outcomeColor(_ outcome: TableCloneOutcome) -> Color {
        switch outcome {
        case .completed: .green
        case .failed, .rolledBack: .red
        case .skipped: .orange
        }
    }

    private func logColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug, .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}

private struct PlanTableRow: View {
    let index: Int
    let table: TableReference
    let selected: Bool
    let progress: TableProgress?
    @Binding var draft: TableFilterDraft
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(index.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Image(systemName: selected ? "checkmark.circle.fill" : "link.circle.fill")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(table.qualifiedName)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if let progress {
                    phaseView(progress)
                }
                if selected {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            if expanded, selected {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("LIMIT").font(.caption)
                        TextField("Use global", text: $draft.limit)
                    }
                    GridRow {
                        Text("WHERE").font(.caption)
                        TextField("Use global", text: $draft.whereClause)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.leading, 56)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func phaseView(_ progress: TableProgress) -> some View {
        if let fraction = progress.fractionCompleted {
            ProgressView(value: fraction)
                .frame(width: 70)
            Text("\(Int(fraction * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        } else {
            Text(progress.phase.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
