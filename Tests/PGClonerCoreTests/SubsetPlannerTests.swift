import Testing
@testable import PGClonerCore

@Suite("Referential subset planner")
struct SubsetPlannerTests {
    let customers = TableReference(name: "customers")
    let orders = TableReference(name: "orders")
    let items = TableReference(name: "order_items")

    @Test("A selected child materializes referenced parent keys")
    func materializesSingleHop() async {
        let foreignKey = ForeignKeyMetadata(
            name: "orders_customer_id_fkey",
            childTable: orders,
            parentTable: customers,
            childColumns: ["customer_id"],
            parentColumns: ["id"]
        )

        let plan = await SubsetPlanner().plan(
            cloneOrder: [customers, orders],
            foreignKeys: [foreignKey],
            selected: [orders],
            filters: [orders: TableFilter(limit: 100, whereClause: "status = 'active'")]
        ) { query in
            #expect(query.sql.contains("status = 'active'"))
            #expect(query.sql.contains("LIMIT 100"))
            return ["2", "1", "2"]
        }

        #expect(plan[customers] == .materialized(keyColumn: "id", values: ["1", "2"]))
    }

    @Test("Intermediate values are reused in a dependency chain")
    func resolvesChain() async {
        let foreignKeys = [
            ForeignKeyMetadata(
                name: "items_order_id_fkey",
                childTable: items,
                parentTable: orders,
                childColumns: ["order_id"],
                parentColumns: ["id"]
            ),
            ForeignKeyMetadata(
                name: "orders_customer_id_fkey",
                childTable: orders,
                parentTable: customers,
                childColumns: ["customer_id"],
                parentColumns: ["id"]
            )
        ]

        let plan = await SubsetPlanner().plan(
            cloneOrder: [customers, orders, items],
            foreignKeys: foreignKeys,
            selected: [items],
            filters: [items: TableFilter()]
        ) { query in
            if query.sql.contains(#""order_items""#) {
                return ["10", "11"]
            }
            #expect(query.textArrayBindings == [["10", "11"]])
            return ["5", "6"]
        }

        #expect(plan[orders] == .materialized(keyColumn: "id", values: ["10", "11"]))
        #expect(plan[customers] == .materialized(keyColumn: "id", values: ["5", "6"]))
    }

    @Test("Large and composite key sets use nested SQL")
    func fallsBack() async {
        let foreignKey = ForeignKeyMetadata(
            name: "line_item_price_fkey",
            childTable: items,
            parentTable: customers,
            childColumns: ["region", "sku"],
            parentColumns: ["region", "sku"]
        )

        let plan = await SubsetPlanner(threshold: 2).plan(
            cloneOrder: [customers, items],
            foreignKeys: [foreignKey],
            selected: [items],
            filters: [:]
        ) { _ in
            Issue.record("Composite keys should not be materialized")
            return []
        }

        #expect(plan[customers] == .nestedSQL)
    }

    @Test("An empty referenced set copies no parent rows")
    func emptyResolution() async {
        let foreignKey = ForeignKeyMetadata(
            name: "orders_customer_id_fkey",
            childTable: orders,
            parentTable: customers,
            childColumns: ["customer_id"],
            parentColumns: ["id"]
        )

        let plan = await SubsetPlanner().plan(
            cloneOrder: [customers, orders],
            foreignKeys: [foreignKey],
            selected: [orders],
            filters: [:]
        ) { _ in [] }

        #expect(plan[customers] == .empty(keyColumn: "id"))
    }
}
