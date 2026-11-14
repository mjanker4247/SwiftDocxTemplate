import XCTest
@testable import SwiftDocxTemplate

final class ExpressionBlockTests: XCTestCase {
    func testComparisonsAndLogic() throws {
        var ctx = ScopeContext(root: [
            "age": .int(30),
            "name": .string("Ada"),
            "flag": .bool(true),
        ])
        var eval = ExpressionEvaluator(context: ctx)

        XCTAssertEqual(try eval.evaluate("age > 18"), .bool(true))
        XCTAssertEqual(try eval.evaluate("age < 18"), .bool(false))
        XCTAssertEqual(try eval.evaluate("name == 'Ada'"), .bool(true))
        XCTAssertEqual(try eval.evaluate("flag and age > 18"), .bool(true))
        XCTAssertEqual(try eval.evaluate("not flag"), .bool(false))
        _ = ctx
    }

    func testFilters() throws {
        let ctx = ScopeContext(root: [
            "name": .string("ada lovelace"),
            "empty": .string(""),
            "n": .double(12.3456),
        ])
        let eval = ExpressionEvaluator(context: ctx)

        XCTAssertEqual(
            try eval.applyFilters([FilterCall(name: "upper", arguments: [])], to: .string("ada")),
            .string("ADA")
        )
        XCTAssertEqual(
            try eval.applyFilters([FilterCall(name: "capitalize", arguments: [])], to: .string("ada")),
            .string("Ada")
        )
        XCTAssertEqual(
            try eval.applyFilters([FilterCall(name: "default", arguments: ["x"])], to: .string("")),
            .string("x")
        )
        let numbered = try eval.applyFilters(
            [FilterCall(name: "number", arguments: ["%.1f"])],
            to: .double(12.3456)
        )
        XCTAssertEqual(numbered, .string("12.3"))

        let dropped = try eval.applyFilters(
            [FilterCall(name: "drop", arguments: ["p"])],
            to: .string("anything")
        )
        XCTAssertEqual(dropped["__drop__"], .string("p"))
    }

    func testScopeResolution() {
        var ctx = ScopeContext(root: [
            "user": .object(["name": .string("Ada")]),
            "items": .array([.object(["sku": .string("A")]), .object(["sku": .string("B")])]),
        ])
        XCTAssertEqual(ctx.resolve(path: "user.name"), .string("Ada"))

        ctx.pushBinding(name: "item", value: .object(["sku": .string("A")]))
        XCTAssertEqual(ctx.resolve(path: "item.sku"), .string("A"))
        XCTAssertEqual(ctx.resolve(path: "sku"), .string("A"))
        ctx.pop()
        XCTAssertEqual(ctx.resolve(path: "sku"), .null)
    }

    func testBlockEvaluatorLoopText() throws {
        var ctx = ScopeContext(root: [
            "items": .array([.string("a"), .string("b"), .string("c")]),
        ])
        var evaluator = BlockEvaluator(context: ctx)
        let nodes: [TemplateNode] = [
            .block(BlockNode(
                open: OpenBlock(
                    kind: .for(item: "item", collection: "items"),
                    scope: .p,
                    raw: "for item in items"
                ),
                body: [.variable(expression: "item", filters: []), .literal(",")],
                elseBody: []
            )),
        ]
        let text = try evaluator.renderText(nodes)
        XCTAssertEqual(text, "a,b,c,")
    }

    func testBlockEvaluatorIfElse() throws {
        var ctx = ScopeContext(root: ["show": .bool(false)])
        var evaluator = BlockEvaluator(context: ctx)
        let nodes: [TemplateNode] = [
            .block(BlockNode(
                open: OpenBlock(kind: .if(condition: "show"), scope: .p, raw: "if show"),
                body: [.literal("yes")],
                elseBody: [.literal("no")]
            )),
        ]
        XCTAssertEqual(try evaluator.renderText(nodes), "no")
    }
}
