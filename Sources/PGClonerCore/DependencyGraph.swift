import Foundation

public struct DependencyGraph: Sendable {
    private let dependencies: [TableReference: Set<TableReference>]
    private let dependents: [TableReference: Set<TableReference>]

    public init(foreignKeys: [ForeignKeyMetadata]) {
        var dependencies: [TableReference: Set<TableReference>] = [:]
        var dependents: [TableReference: Set<TableReference>] = [:]

        for foreignKey in foreignKeys {
            dependencies[foreignKey.childTable, default: []].insert(foreignKey.parentTable)
            dependents[foreignKey.parentTable, default: []].insert(foreignKey.childTable)
            dependencies[foreignKey.parentTable, default: []] = dependencies[foreignKey.parentTable, default: []]
            dependents[foreignKey.childTable, default: []] = dependents[foreignKey.childTable, default: []]
        }

        self.dependencies = dependencies
        self.dependents = dependents
    }

    public func directDependencies(of table: TableReference) -> Set<TableReference> {
        dependencies[table, default: []]
    }

    public func directDependents(of table: TableReference) -> Set<TableReference> {
        dependents[table, default: []]
    }

    public func requiredTables(for selected: Set<TableReference>) -> Set<TableReference> {
        var required = selected
        var pending = Array(selected)

        while let table = pending.popLast() {
            for parent in directDependencies(of: table) where required.insert(parent).inserted {
                pending.append(parent)
            }
        }

        return required
    }

    public func plan(for selectedTables: [TableReference]) -> ClonePlan {
        let selected = Set(selectedTables)
        let all = requiredTables(for: selected)
        let sorted = topologicalSort(all)
        let required = all.subtracting(selected).sorted()

        return ClonePlan(
            selected: selected.sorted(),
            required: required,
            ordered: sorted.order,
            cyclicTables: sorted.cyclic
        )
    }

    public func topologicalSort(_ tables: Set<TableReference>) -> (
        order: [TableReference],
        cyclic: Set<TableReference>
    ) {
        var inDegree: [TableReference: Int] = [:]
        for table in tables {
            inDegree[table] = directDependencies(of: table).intersection(tables).count
        }

        var ready = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var result: [TableReference] = []

        while !ready.isEmpty {
            let table = ready.removeFirst()
            guard inDegree.removeValue(forKey: table) != nil else { continue }
            result.append(table)

            for child in directDependents(of: table).intersection(tables).sorted() {
                guard let degree = inDegree[child] else { continue }
                let next = degree - 1
                inDegree[child] = next
                if next == 0 {
                    ready.append(child)
                    ready.sort()
                }
            }
        }

        let cyclic = Set(inDegree.keys)
        result.append(contentsOf: cyclic.sorted())
        return (result, cyclic)
    }
}
