import XCTest
@testable import SwiftDocxTemplate
import AEXML

final class LexerParserTests: XCTestCase {
    func testLexesMustacheVariableWithFilters() throws {
        let tokens = try TemplateLexer("Hello {{ name | upper | default('x') }}!").tokenize()
        XCTAssertEqual(tokens.count, 3)
        guard case .literal("Hello ") = tokens[0] else { return XCTFail() }
        guard case .variable(let expr, let filters) = tokens[1] else { return XCTFail() }
        XCTAssertEqual(expr, "name")
        XCTAssertEqual(filters.map(\.name), ["upper", "default"])
        XCTAssertEqual(filters[1].arguments, ["x"])
        guard case .literal("!") = tokens[2] else { return XCTFail() }
    }

    func testLexesDocxtplForLoop() throws {
        let tokens = try TemplateLexer("{%tr for item in items %}{{ item }}{% endtr %}").tokenize()
        XCTAssertEqual(tokens.count, 3)
        guard case .openBlock(let open) = tokens[0] else { return XCTFail() }
        XCTAssertEqual(open.scope, .tr)
        guard case .for(let item, let collection) = open.kind else { return XCTFail() }
        XCTAssertEqual(item, "item")
        XCTAssertEqual(collection, "items")
        guard case .variable(let expr, _) = tokens[1] else { return XCTFail() }
        XCTAssertEqual(expr, "item")
        guard case .closeBlock = tokens[2] else { return XCTFail() }
    }

    func testLexesDocxtemplaterBlocks() throws {
        let tokens = try TemplateLexer("{#items}{{.}}{/items}").tokenize()
        guard case .openBlock(let open) = tokens[0] else { return XCTFail("open") }
        guard case .for(_, let collection) = open.kind else { return XCTFail("for") }
        XCTAssertEqual(collection, "items")
        guard case .closeBlock(let tag) = tokens[2] else { return XCTFail("close") }
        XCTAssertEqual(tag, "items")
    }

    func testLexesInvertedSection() throws {
        let tokens = try TemplateLexer("{^empty}none{/empty}").tokenize()
        guard case .openBlock(let open) = tokens[0] else { return XCTFail() }
        guard case .unless(let cond) = open.kind else { return XCTFail() }
        XCTAssertEqual(cond, "empty")
    }

    func testParsesNestedIfElse() throws {
        var parser = try TemplateParser(source: "{%p if show %}yes{% else %}no{% endp %}")
        let nodes = try parser.parse()
        XCTAssertEqual(nodes.count, 1)
        guard case .block(let block) = nodes[0] else { return XCTFail() }
        XCTAssertEqual(block.body, [.literal("yes")])
        XCTAssertEqual(block.elseBody, [.literal("no")])
    }

    func testCollectsVariables() throws {
        var parser = try TemplateParser(source: "Hi {{ user.name }} {% if flag %}{{ x }}{% endif %}")
        let nodes = try parser.parse()
        let vars = TemplateAST.collectVariables(in: nodes)
        XCTAssertTrue(vars.contains("user.name"))
        XCTAssertTrue(vars.contains("flag"))
        XCTAssertTrue(vars.contains("x"))
    }

    func testDOMScopeResolverPrefersRow() throws {
        let xml = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:tbl>
              <w:tr>
                <w:tc>
                  <w:p>
                    <w:r><w:t>{%tr for i in items %}</w:t></w:r>
                  </w:p>
                </w:tc>
              </w:tr>
            </w:tbl>
          </w:body>
        </w:document>
        """
        let doc = try AEXMLDocument(xml: xml)
        let run = findFirst(doc.root, named: "r")!
        let host = DOMScopeResolver.resolveHost(for: .tr, from: run)
        XCTAssertEqual(DOMScopeResolver.localName(host), "tr")

        let auto = DOMScopeResolver.resolveHost(for: .auto, from: run)
        XCTAssertEqual(DOMScopeResolver.localName(auto), "tr")
    }

    private func findFirst(_ el: AEXMLElement, named local: String) -> AEXMLElement? {
        if DOMScopeResolver.isWord(el, local) { return el }
        for child in el.children {
            if let found = findFirst(child, named: local) { return found }
        }
        return nil
    }
}
