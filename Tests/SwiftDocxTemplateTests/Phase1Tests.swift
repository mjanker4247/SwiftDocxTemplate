import XCTest
@testable import SwiftDocxTemplate
import Foundation
import ZIPFoundation

final class Phase1Tests: XCTestCase {
    func testTemplateValueLiterals() {
        let null: TemplateValue = nil
        XCTAssertEqual(null, .null)

        let flag: TemplateValue = true
        XCTAssertEqual(flag, .bool(true))

        let number: TemplateValue = 42
        XCTAssertEqual(number, .int(42))

        let text: TemplateValue = "hello"
        XCTAssertEqual(text, .string("hello"))

        let list: TemplateValue = ["a", 1]
        XCTAssertEqual(list, .array([.string("a"), .int(1)]))

        let obj: TemplateValue = ["name": "Ada", "age": 36]
        XCTAssertEqual(obj["name"], .string("Ada"))
        XCTAssertEqual(obj["age"], .int(36))
    }

    func testTemplateValueEncoderFlatStruct() throws {
        struct Person: Encodable {
            let name: String
            let age: Int
            let active: Bool
        }

        let context = try TemplateValueEncoder().encode(Person(name: "Ada", age: 36, active: true))
        XCTAssertEqual(context["name"], .string("Ada"))
        XCTAssertEqual(context["age"], .int(36))
        XCTAssertEqual(context["active"], .bool(true))
    }

    func testTemplateValueEncoderNestedAndArray() throws {
        struct Item: Encodable {
            let sku: String
            let qty: Int
        }
        struct Order: Encodable {
            let id: String
            let items: [Item]
        }

        let context = try TemplateValueEncoder().encode(
            Order(id: "O-1", items: [Item(sku: "A", qty: 2), Item(sku: "B", qty: 1)])
        )
        XCTAssertEqual(context["id"], .string("O-1"))
        guard case .array(let items)? = context["items"] else {
            return XCTFail("items should be an array")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["sku"], .string("A"))
        XCTAssertEqual(items[1]["qty"], .int(1))
    }

    func testDocxArchiveRoundTrip() throws {
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Hello {{ name }}</w:t></w:r></w:p></w:body>
        </w:document>
        """.data(using: .utf8)!

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """.data(using: .utf8)!

        let archive = DocxArchive(entries: [
            "[Content_Types].xml": contentTypes,
            "word/document.xml": docXML,
        ])
        let bytes = try archive.serialize()
        let reopened = try DocxArchive(data: bytes)
        XCTAssertEqual(reopened.documentXML, docXML)

        let template = try DocxTemplate(data: bytes)
        let rendered = try template.render(context: ["name": .string("World")])
        XCTAssertFalse(rendered.isEmpty)

        let undeclared = try template.getUndeclaredVariables()
        XCTAssertEqual(undeclared, ["name"])
    }

    func testDocxTemplateRejectsInvalidArchive() {
        XCTAssertThrowsError(try DocxTemplate(data: Data("not-a-zip".utf8))) { error in
            XCTAssertEqual(error as? DocxTemplateError, .invalidArchive)
        }
    }
}
