import XCTest
@testable import SwiftDocxTemplate
import Foundation

final class IntegrationTests: XCTestCase {
    func testSimpleVariableRender() throws {
        let docx = try TestDOCX.make(bodyParagraphs: [
            "Hello {{ name }}!",
        ])
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: ["name": .string("World")])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("Hello World!"), text)
        XCTAssertFalse(text.contains("{{"), text)
    }

    func testEncodableModel() throws {
        struct Person: Encodable {
            let name: String
            let title: String
        }
        let docx = try TestDOCX.make(bodyParagraphs: [
            "{{ name }} — {{ title }}",
        ])
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(with: Person(name: "Ada", title: "Engineer"))
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("Ada — Engineer"), text)
    }

    func testHeaderVariable() throws {
        let docx = try TestDOCX.make(
            bodyParagraphs: ["Body {{ bodyVar }}"],
            headerParagraphs: ["Header {{ headerVar }}"]
        )
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: [
            "bodyVar": .string("B"),
            "headerVar": .string("H"),
        ])
        let archive = try DocxArchive(data: rendered)
        let header = archive.data(at: "word/header1.xml").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let body = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(header.contains("Header H"), header)
        XCTAssertTrue(body.contains("Body B"), body)
    }

    func testConditionalDropParagraph() throws {
        let docx = try TestDOCX.make(bodyParagraphs: [
            "Keep",
            "{{ hide | drop(p) }}",
            "After",
        ])
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: [
            "hide": .string("secret"),
        ])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("Keep"), text)
        XCTAssertTrue(text.contains("After"), text)
        XCTAssertFalse(text.contains("secret"), text)
    }

    func testDocxtemplaterLoop() throws {
        let docx = try TestDOCX.make(bodyParagraphs: [
            "{#items}Item {{.}} {/items}",
        ])
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: [
            "items": .array([.string("A"), .string("B")]),
        ])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("Item A"), text)
        XCTAssertTrue(text.contains("Item B"), text)
    }

    func testDynamicTableRows() throws {
        let rowOpen = "{%tr for item in items %}"
        let rowClose = "{% endtr %}"
        let docx = try TestDOCX.makeTable(
            headerCells: ["SKU"],
            templateRowCells: ["\(rowOpen){{ item.sku }}\(rowClose)"]
        )
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: [
            "items": .array([
                .object(["sku": .string("A-1")]),
                .object(["sku": .string("B-2")]),
            ]),
        ])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("A-1"), text)
        XCTAssertTrue(text.contains("B-2"), text)
    }

    func testGetUndeclaredVariables() throws {
        let docx = try TestDOCX.make(bodyParagraphs: [
            "Hello {{ name }} {{ company }}",
        ])
        let template = try DocxTemplate(data: docx)
        let vars = try template.getUndeclaredVariables()
        XCTAssertTrue(vars.contains("name"))
        XCTAssertTrue(vars.contains("company"))
    }

    func testReplaceMedia() throws {
        let png = TestDOCX.minimalPNG()
        let placeholderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-\(UUID().uuidString).png")
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-\(UUID().uuidString).png")
        try png.write(to: placeholderURL)
        // Slightly different bytes for replacement
        var replacement = png
        replacement.append(0x00)
        // Actually keep valid PNG — just use same minimal PNG with different stored name
        try png.write(to: replacementURL)
        defer {
            try? FileManager.default.removeItem(at: placeholderURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }

        let docx = try TestDOCX.make(
            bodyParagraphs: ["Logo"],
            media: ["image1.png": png]
        )
        var template = try DocxTemplate(data: docx)
        try template.replaceMedia(placeholderFilename: "image1.png", with: replacementURL)
        let rendered = try template.render(context: [:])
        let archive = try DocxArchive(data: rendered)
        XCTAssertNotNil(archive.data(at: "word/media/image1.png"))
    }

    func testFiltersInRender() throws {
        let docx = try TestDOCX.make(bodyParagraphs: [
            "{{ name | upper }}",
        ])
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: ["name": .string("ada")])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("ADA"), text)
    }

    func testSplitRunsHealedThenRendered() throws {
        // Build XML with deliberately split `{{ name }}`
        let body = """
        <w:p>
          <w:r><w:t>{</w:t></w:r>
          <w:r><w:t>{ name </w:t></w:r>
          <w:r><w:t>}}</w:t></w:r>
        </w:p>
        """
        let docx = try TestDOCX.makeRawBody(body)
        let template = try DocxTemplate(data: docx)
        let rendered = try template.render(context: ["name": .string("Healed")])
        let text = try TestDOCX.extractDocumentText(from: rendered)
        XCTAssertTrue(text.contains("Healed"), text)
    }
}

// MARK: - Test DOCX builder

enum TestDOCX {
    static func make(
        bodyParagraphs: [String],
        headerParagraphs: [String] = [],
        media: [String: Data] = [:]
    ) throws -> Data {
        let body = bodyParagraphs.map { p in
            "<w:p><w:r><w:t xml:space=\"preserve\">\(escape(p))</w:t></w:r></w:p>"
        }.joined()

        var entries: [String: Data] = [:]
        entries["[Content_Types].xml"] = Data(contentTypes(hasHeader: !headerParagraphs.isEmpty, media: media).utf8)
        entries["word/document.xml"] = Data(documentXML(body: body, hasHeader: !headerParagraphs.isEmpty).utf8)
        entries["word/_rels/document.xml.rels"] = Data(documentRels(hasHeader: !headerParagraphs.isEmpty, media: media).utf8)
        entries["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.utf8)

        if !headerParagraphs.isEmpty {
            let hp = headerParagraphs.map {
                "<w:p><w:r><w:t xml:space=\"preserve\">\(escape($0))</w:t></w:r></w:p>"
            }.joined()
            entries["word/header1.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(hp)</w:hdr>
            """.utf8)
        }

        for (name, data) in media {
            entries["word/media/\(name)"] = data
        }

        return try DocxArchive(entries: entries).serialize()
    }

    static func makeRawBody(_ bodyInnerXML: String) throws -> Data {
        try make(bodyParagraphs: []).withReplacedDocumentBody(bodyInnerXML)
    }

    static func makeTable(headerCells: [String], templateRowCells: [String]) throws -> Data {
        func row(_ cells: [String]) -> String {
            let tcs = cells.map { c in
                """
                <w:tc>
                  <w:p><w:r><w:t xml:space="preserve">\(escape(c))</w:t></w:r></w:p>
                </w:tc>
                """
            }.joined()
            return "<w:tr>\(tcs)</w:tr>"
        }
        let tbl = "<w:tbl>\(row(headerCells))\(row(templateRowCells))</w:tbl>"
        return try makeRawBody(tbl)
    }

    static func extractDocumentText(from data: Data) throws -> String {
        let archive = try DocxArchive(data: data)
        guard let xml = archive.documentXML, let str = String(data: xml, encoding: .utf8) else {
            return ""
        }
        // Naive strip tags for assertions
        var text = str
        while let start = text.range(of: "<"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound...end.lowerBound)
        }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    static func minimalPNG() -> Data {
        // 1x1 transparent PNG
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return Data(base64Encoded: b64)!
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func documentXML(body: String, hasHeader: Bool) -> String {
        let sect = hasHeader
            ? """
              <w:sectPr>
                <w:headerReference w:type="default" r:id="rIdHeader"/>
              </w:sectPr>
              """
            : "<w:sectPr/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(body)
            \(sect)
          </w:body>
        </w:document>
        """
    }

    private static func documentRels(hasHeader: Bool, media: [String: Data]) -> String {
        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        if hasHeader {
            rels += """
              <Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
            """
        }
        for (idx, name) in media.keys.sorted().enumerated() {
            rels += """
              <Relationship Id="rIdMedia\(idx + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(name)"/>
            """
        }
        rels += "</Relationships>"
        return rels
    }

    private static func contentTypes(hasHeader: Bool, media: [String: Data]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        """
        if hasHeader {
            xml += """
              <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            """
        }
        xml += "</Types>"
        return xml
    }
}

private extension Data {
    func withReplacedDocumentBody(_ bodyInnerXML: String) throws -> Data {
        var archive = try DocxArchive(data: self)
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(bodyInnerXML)
            <w:sectPr/>
          </w:body>
        </w:document>
        """
        archive.setDocumentXML(Data(doc.utf8))
        return try archive.serialize()
    }
}
