import Testing
@testable import PGClonerCore

@Suite("Dependency graph")
struct DependencyGraphTests {
    private let customers = TableReference(name: "customers")
    private let orders = TableReference(name: "orders")
    private let items = TableReference(name: "order_items")

    @Test("Parents are automatically included and ordered first")
    func resolvesDependencies() {
        let graph = DependencyGraph(foreignKeys: [
            ForeignKeyMetadata(
                name: "orders_customer_id_fkey",
                childTable: orders,
                parentTable: customers,
                childColumns: ["customer_id"],
                parentColumns: ["id"]
            ),
            ForeignKeyMetadata(
                name: "items_order_id_fkey",
                childTable: items,
                parentTable: orders,
                childColumns: ["order_id"],
                parentColumns: ["id"]
            )
        ])

        let plan = graph.plan(for: [items])

        #expect(plan.selected == [items])
        #expect(plan.required == [customers, orders])
        #expect(plan.ordered == [customers, orders, items])
        #expect(!plan.containsCycle)
    }

    @Test("Cycles are reported and remain in a deterministic order")
    func reportsCycle() {
        let alpha = TableReference(name: "alpha")
        let beta = TableReference(name: "beta")
        let graph = DependencyGraph(foreignKeys: [
            ForeignKeyMetadata(
                name: "alpha_beta",
                childTable: alpha,
                parentTable: beta,
                childColumns: ["beta_id"],
                parentColumns: ["id"]
            ),
            ForeignKeyMetadata(
                name: "beta_alpha",
                childTable: beta,
                parentTable: alpha,
                childColumns: ["alpha_id"],
                parentColumns: ["id"]
            )
        ])

        let plan = graph.plan(for: [alpha])

        #expect(plan.cyclicTables == Set([alpha, beta]))
        #expect(plan.ordered == [alpha, beta])
    }
}
