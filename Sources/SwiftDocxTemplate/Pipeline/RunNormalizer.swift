import Foundation
import AEXML

/// Stage 1 of the rendering pipeline.
///
/// 1. Merges adjacent `w:r` elements that share identical `w:rPr`.
/// 2. Heals template delimiters (`{{`, `{%`, `{#`, `{/`) that Word split across runs.
enum RunNormalizer {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// Delimiter prefixes that must appear intact for the lexer.
    static let delimiterPrefixes: [String] = ["{{", "{%", "{#", "{/", "}}", "%}"]

    /// Shared parse options — Word `w:t` nodes rely on preserved spaces.
    static var xmlOptions: AEXMLOptions {
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        options.documentHeader.standalone = "yes"
        return options
    }

    /// Normalizes all paragraphs inside a WordprocessingML document/header/footer root.
    static func normalize(xml data: Data) throws -> Data {
        let document: AEXMLDocument
        do {
            document = try AEXMLDocument(xml: data, options: xmlOptions)
        } catch {
            throw DocxTemplateError.malformedXML(String(describing: error))
        }
        normalize(element: document.root)
        return document.xmlCompact.data(using: .utf8) ?? document.xml.data(using: .utf8) ?? data
    }

    /// Recursively walks the tree and normalizes every paragraph (`w:p`).
    static func normalize(element: AEXMLElement) {
        if isWordElement(element, named: "p") {
            normalizeParagraph(element)
        }
        for child in element.children {
            normalize(element: child)
        }
    }

    // MARK: - Paragraph

    static func normalizeParagraph(_ paragraph: AEXMLElement) {
        mergeIdenticalRuns(in: paragraph)
        healDelimiters(in: paragraph)
        // A second merge pass collapses runs created/emptied during healing.
        mergeIdenticalRuns(in: paragraph)
        removeEmptyRuns(in: paragraph)
    }

    // MARK: - Identical rPr merge

    static func mergeIdenticalRuns(in paragraph: AEXMLElement) {
        var index = 0
        while index < paragraph.children.count {
            let current = paragraph.children[index]
            guard isRun(current) else {
                index += 1
                continue
            }

            let lookAhead = index + 1
            while lookAhead < paragraph.children.count {
                let next = paragraph.children[lookAhead]
                guard isRun(next) else { break }
                guard identicalRunProperties(current, next) else { break }
                // Only merge simple text runs (no drawings / tabs / breaks complexity beyond w:t).
                guard isSimpleTextRun(current), isSimpleTextRun(next) else { break }

                appendText(from: next, onto: current)
                paragraph.removeChild(next)
                // `removeChild` shifts subsequent children; do not increment lookAhead.
            }
            index += 1
        }
    }

    // MARK: - Delimiter healing

    /// Ensures delimiter prefixes are not split across adjacent run boundaries.
    static func healDelimiters(in paragraph: AEXMLElement) {
        var index = 0
        while index < paragraph.children.count {
            let current = paragraph.children[index]
            guard isRun(current), isSimpleTextRun(current) else {
                index += 1
                continue
            }

            var changed = false
            // Pull characters forward while the joined boundary still looks like a split delimiter.
            while index + 1 < paragraph.children.count {
                let next = paragraph.children[index + 1]
                guard isRun(next), isSimpleTextRun(next) else { break }

                let left = runText(current)
                let right = runText(next)
                guard needsDelimiterHeal(left: left, right: right) else { break }

                let (moved, remaining) = peelDelimiterFragment(left: left, right: right)
                guard !moved.isEmpty else { break }

                setRunText(current, left + moved)
                if remaining.isEmpty {
                    paragraph.removeChild(next)
                } else {
                    setRunText(next, remaining)
                }
                changed = true
            }

            if !changed {
                index += 1
            }
            // If changed, re-evaluate the same index (text grew; next sibling may still need healing).
        }
    }

    /// Returns true when a delimiter prefix straddles the boundary between `left` and `right`.
    static func needsDelimiterHeal(left: String, right: String) -> Bool {
        guard !right.isEmpty else { return false }
        let joined = left + right
        for delimiter in delimiterPrefixes {
            // Already complete inside left — no heal needed for this delimiter.
            if left.contains(delimiter) { continue }
            // Exists only when joined, and left ends with a proper prefix of the delimiter.
            guard joined.contains(delimiter) else { continue }
            for prefixLen in 1..<delimiter.count {
                let prefix = String(delimiter.prefix(prefixLen))
                if left.hasSuffix(prefix) {
                    return true
                }
            }
            // Also heal when left ends mid-tag after an opener already started earlier in left,
            // e.g. left="{{na" right="me}}" — not a delimiter *prefix* split, but closing `}}`
            // may still be split: left="{{name}" right="}".
            if delimiter.count == 2 {
                let first = String(delimiter.prefix(1))
                let second = String(delimiter.suffix(1))
                if left.hasSuffix(first), right.hasPrefix(second) {
                    return true
                }
            }
        }
        return false
    }

    /// Moves the smallest number of characters from `right` onto `left` to complete a split delimiter.
    static func peelDelimiterFragment(left: String, right: String) -> (moved: String, remaining: String) {
        let joined = left + right
        var bestMove = 0

        for delimiter in delimiterPrefixes {
            for prefixLen in 1..<delimiter.count {
                let prefix = String(delimiter.prefix(prefixLen))
                guard left.hasSuffix(prefix) else { continue }
                let needed = delimiter.count - prefixLen
                guard needed > 0, right.count >= needed else { continue }
                let candidate = left + String(right.prefix(needed))
                if candidate.hasSuffix(delimiter) || joined.contains(delimiter) {
                    bestMove = max(bestMove, needed)
                }
            }
            // Single-character straddles for 2-char delimiters: `{` | `{`
            if delimiter.count == 2 {
                let first = String(delimiter.prefix(1))
                let second = String(delimiter.suffix(1))
                if left.hasSuffix(first), right.hasPrefix(second) {
                    bestMove = max(bestMove, 1)
                }
            }
        }

        // Fallback: if any delimiter appears only in the join, move characters until the first
        // occurrence of a delimiter that starts in `left` completes.
        if bestMove == 0 {
            for delimiter in delimiterPrefixes {
                if let range = joined.range(of: delimiter) {
                    let startOffset = joined.distance(from: joined.startIndex, to: range.lowerBound)
                    let endOffset = startOffset + delimiter.count
                    if startOffset < left.count, endOffset > left.count {
                        bestMove = max(bestMove, endOffset - left.count)
                    }
                }
            }
        }

        guard bestMove > 0 else { return ("", right) }
        let moveCount = min(bestMove, right.count)
        let moved = String(right.prefix(moveCount))
        let remaining = String(right.dropFirst(moveCount))
        return (moved, remaining)
    }

    // MARK: - Empty run cleanup

    static func removeEmptyRuns(in paragraph: AEXMLElement) {
        let empties = paragraph.children.filter { child in
            isRun(child) && isSimpleTextRun(child) && runText(child).isEmpty && !hasNonTextContent(child)
        }
        for empty in empties {
            // Keep runs that only exist to hold rPr with no text? Drop them — safe for templates.
            paragraph.removeChild(empty)
        }
    }

    // MARK: - Run helpers

    static func isWordElement(_ element: AEXMLElement, named localName: String) -> Bool {
        let name = element.name
        return name == localName
            || name == "w:\(localName)"
            || name.hasSuffix(":\(localName)")
    }

    static func isRun(_ element: AEXMLElement) -> Bool {
        isWordElement(element, named: "r")
    }

    static func runPropertiesXML(_ run: AEXMLElement) -> String {
        for child in run.children where isWordElement(child, named: "rPr") {
            return canonicalXML(child)
        }
        return ""
    }

    static func identicalRunProperties(_ a: AEXMLElement, _ b: AEXMLElement) -> Bool {
        runPropertiesXML(a) == runPropertiesXML(b)
    }

    static func isSimpleTextRun(_ run: AEXMLElement) -> Bool {
        // Allow w:rPr and one or more w:t / w:tab / w:br — but healing/merge operate on w:t only.
        // Reject runs that contain drawings or complex fields.
        for child in run.children {
            if isWordElement(child, named: "rPr") { continue }
            if isWordElement(child, named: "t") { continue }
            if isWordElement(child, named: "tab") { continue }
            if isWordElement(child, named: "br") { continue }
            if isWordElement(child, named: "cr") { continue }
            return false
        }
        return true
    }

    static func hasNonTextContent(_ run: AEXMLElement) -> Bool {
        run.children.contains { child in
            isWordElement(child, named: "tab")
                || isWordElement(child, named: "br")
                || isWordElement(child, named: "cr")
                || isWordElement(child, named: "drawing")
        }
    }

    static func runText(_ run: AEXMLElement) -> String {
        run.children
            .filter { isWordElement($0, named: "t") }
            .map { $0.string }
            .joined()
    }

    static func setRunText(_ run: AEXMLElement, _ text: String) {
        let textNodes = run.children.filter { isWordElement($0, named: "t") }
        if let first = textNodes.first {
            first.value = text
            if text.contains(" ") || text.hasPrefix(" ") || text.hasSuffix(" ") {
                first.attributes["xml:space"] = "preserve"
            }
            for extra in textNodes.dropFirst() {
                run.removeChild(extra)
            }
        } else {
            let t = run.addChild(name: "w:t", value: text)
            if text.contains(" ") || text.hasPrefix(" ") || text.hasSuffix(" ") {
                t.attributes["xml:space"] = "preserve"
            }
        }
    }

    static func appendText(from source: AEXMLElement, onto destination: AEXMLElement) {
        let combined = runText(destination) + runText(source)
        setRunText(destination, combined)
    }

    static func canonicalXML(_ element: AEXMLElement) -> String {
        // Compact, order-stable serialization for equality checks.
        var attrs = element.attributes.keys.sorted().map { key in
            "\(key)=\"\(element.attributes[key] ?? "")\""
        }.joined(separator: " ")
        if !attrs.isEmpty { attrs = " " + attrs }
        if element.children.isEmpty {
            let value = element.value ?? ""
            if value.isEmpty {
                return "<\(element.name)\(attrs)/>"
            }
            return "<\(element.name)\(attrs)>\(value)</\(element.name)>"
        }
        let kids = element.children.map { canonicalXML($0) }.joined()
        return "<\(element.name)\(attrs)>\(kids)</\(element.name)>"
    }
}

// MARK: - AEXML helpers

private extension AEXMLElement {
    func removeChild(_ child: AEXMLElement) {
        child.removeFromParent()
    }
}
