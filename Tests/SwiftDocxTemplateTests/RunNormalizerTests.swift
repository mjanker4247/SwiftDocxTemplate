import XCTest
@testable import SwiftDocxTemplate
import AEXML
import Foundation

final class RunNormalizerTests: XCTestCase {
    func testMergesIdenticalRuns() throws {
        let xml = paragraphXML(runs: [
            ("Hello ", nil),
            ("{{ name", nil),
            (" }}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts, ["Hello {{ name }}"])
    }

    func testDoesNotMergeDifferentRPr() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:r>
                <w:rPr><w:b/></w:rPr>
                <w:t>Bold</w:t>
              </w:r>
              <w:r>
                <w:t>Plain</w:t>
              </w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts, ["Bold", "Plain"])
    }

    func testHealsSplitOpenDelimiter() throws {
        // `{` | `{ name }}`
        let xml = paragraphXML(runs: [
            ("{", nil),
            ("{ name }}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts[0], "{{ name }}")
    }

    func testHealsSplitCloseDelimiter() throws {
        let xml = paragraphXML(runs: [
            ("{{ name }", nil),
            ("}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts, ["{{ name }}"])
    }

    func testHealsDocxtplPercentDelimiter() throws {
        // `{` | `%tr for item in items %}`
        let xml = paragraphXML(runs: [
            ("{", nil),
            ("%tr for item in items %}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts, ["{%tr for item in items %}"])
    }

    func testHealsDocxtemplaterBlockDelimiter() throws {
        // `{` | `#items}` ... `{` | `/items}`
        let xml = paragraphXML(runs: [
            ("{", nil),
            ("#items}", nil),
            (" row ", nil),
            ("{", nil),
            ("/items}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let joined = try extractRunTexts(from: normalized).joined()
        XCTAssertTrue(joined.contains("{#items}"))
        XCTAssertTrue(joined.contains("{/items}"))
        XCTAssertFalse(joined.contains("{#") && joined.split(separator: "{").contains(where: { $0.hasPrefix("#") == false && false }))
    }

    func testHealsAcrossFormattingBoundaryWhenDelimiterSplit() throws {
        // Bold `{` then plain `{name}}` — heal must move `{` even when rPr differs.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:r>
                <w:rPr><w:b/></w:rPr>
                <w:t>{</w:t>
              </w:r>
              <w:r>
                <w:t>{name}}</w:t>
              </w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        // After healing, first run should contain `{{` (or full tag if merge also applied).
        XCTAssertTrue(texts.joined().contains("{{name}}"))
        XCTAssertEqual(texts.first?.hasPrefix("{{") ?? false, true)
    }

    func testPreservesSpacesWithXmlSpace() throws {
        let xml = paragraphXML(runs: [
            ("{{ ", nil),
            ("name", nil),
            (" }}", nil),
        ])
        let normalized = try RunNormalizer.normalize(xml: Data(xml.utf8))
        let texts = try extractRunTexts(from: normalized)
        XCTAssertEqual(texts, ["{{ name }}"])
    }

    // MARK: - Helpers

    private func paragraphXML(runs: [(String, String?)]) -> String {
        let runXML = runs.map { text, rPr in
            let props: String
            if let rPr, !rPr.isEmpty {
                props = "<w:rPr>\(rPr)</w:rPr>"
            } else {
                props = ""
            }
            return "<w:r>\(props)<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }.joined()

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>\(runXML)</w:p>
          </w:body>
        </w:document>
        """
    }

    private func extractRunTexts(from data: Data) throws -> [String] {
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        let doc = try AEXMLDocument(xml: data, options: options)
        var texts: [String] = []
        func walk(_ el: AEXMLElement) {
            if el.name == "w:r" || el.name.hasSuffix(":r") || el.name == "r" {
                let t = el.children
                    .filter { $0.name == "w:t" || $0.name.hasSuffix(":t") || $0.name == "t" }
                    .map { $0.string }
                    .joined()
                texts.append(t)
            }
            for child in el.children { walk(child) }
        }
        walk(doc.root)
        return texts
    }
}
