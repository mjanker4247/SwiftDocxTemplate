import XCTest
@testable import SwiftDocxTemplate
import Foundation

final class QuickstartRenderTest: XCTestCase {
    func testQuickstartTemplateRendersBlocks() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/Quickstart/ReportTemplate.docx")
        let logo = url.deletingLastPathComponent().appendingPathComponent("logo.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)

        let template = try DocxTemplate(templateURL: url)
        var context: [String: TemplateValue] = [
            "company": .object([
                "name": .string("Acme"),
                "address": .object(["city": .string("Berlin"), "country": .string("DE")]),
            ]),
            "reportTitle": .string("Title"),
            "reportDate": .date(Date(timeIntervalSince1970: 1_731_456_000)),
            "status": .string("draft"),
            "productName": .string("swiftDocx"),
            "nickname": .string(""),
            "total": .double(1.5),
            "multiLineNotes": .string("a\nb"),
            "customer": .object(["name": .string("Ada"), "title": .string("eng")]),
            "showPremium": .bool(true),
            "hasNotes": .bool(false),
            "notes": .array([.string("n1"), .string("n2")]),
            "tags": .array([.string("t1"), .string("t2")]),
            "items": .array([
                .object(["sku": .string("A-1"), "qty": .int(2), "price": .double(3.5)]),
            ]),
            "discardedNote": .string("gone"),
            "hiddenRow": .string("gone-row"),
            "summary": .string("sum"),
        ]
        context["logo"] = .image(InlineImage(url: logo, widthMm: 10, heightMm: 10))

        let rendered = try template.render(context: context)
        let text = try TestDOCX.extractDocumentText(from: rendered)

        XCTAssertFalse(text.contains("{%"), text)
        XCTAssertFalse(text.contains("{#"), text)
        XCTAssertFalse(text.contains("{^"), text)
        XCTAssertTrue(text.contains("Premium banner"), text)
        XCTAssertTrue(text.contains("Inverted section"), text)
        XCTAssertTrue(text.contains("n1"), text)
        XCTAssertTrue(text.contains("A-1"), text)
        XCTAssertTrue(text.contains("t1"), text)
        XCTAssertFalse(text.contains("gone"), text)
        XCTAssertFalse(text.contains("Visible row"), text)
    }

    func testEmptyStringArrayDoesNotBecomeRichText() throws {
        struct Model: Encodable {
            var emptyNotes: [String]
        }
        let context = try TemplateValueEncoder().encode(Model(emptyNotes: []))
        XCTAssertEqual(context["emptyNotes"], .array([]))
    }
}
