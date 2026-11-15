import Foundation
import AEXML

/// Stage 5 — injects images and rich text, escapes XML text, and sets `xml:space`.
struct MediaInjector {
    var archive: DocxArchive
    private var nextImageId: Int = 1
    private var nextDocPrId: Int = 1
    private var relationshipIdCounter: Int = 100

    init(archive: DocxArchive) {
        self.archive = archive
    }

    /// Walks the document XML and replaces image / richText placeholders that remain as markers,
    /// while escaping ordinary text and preserving spaces.
    mutating func process(xml data: Data, context: ScopeContext) throws -> Data {
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        options.documentHeader.standalone = "yes"
        let document: AEXMLDocument
        do {
            document = try AEXMLDocument(xml: data, options: options)
        } catch {
            throw DocxTemplateError.malformedXML(String(describing: error))
        }

        try processElement(document.root, context: context)
        return document.xmlCompact.data(using: .utf8) ?? data
    }

    private mutating func processElement(_ element: AEXMLElement, context: ScopeContext) throws {
        // Handle drop markers left as empty paragraphs/rows later via attribute scan.
        if DOMScopeResolver.isWord(element, "t") {
            try processTextNode(element, context: context)
        }

        // Snapshot children — processTextNode may mutate siblings.
        let kids = element.children
        for child in kids {
            try processElement(child, context: context)
        }
    }

    private mutating func processTextNode(_ textNode: AEXMLElement, context: ScopeContext) throws {
        let raw = textNode.value ?? ""
        // Detect leftover special markers: <<IMAGE:path>> or <<RICH:...>> — used by BlockEvaluator.
        if raw.hasPrefix("<<IMAGE:"), raw.hasSuffix(">>") {
            let key = String(raw.dropFirst(8).dropLast(2))
            if case .image(let image) = context.resolve(path: key) {
                try replaceRunWithDrawing(textNode: textNode, image: image)
                return
            }
        }

        // Escape is handled by AEXML on serialization; ensure xml:space for leading/trailing spaces.
        if raw.contains(" ") || raw.hasPrefix(" ") || raw.hasSuffix(" ") || raw.contains("\t") {
            textNode.attributes["xml:space"] = "preserve"
        }

        // Convert linebreak markers from the `linebreaks` filter into Word break elements.
        if raw.contains("\u{2028}"), let run = textNode.parent {
            try expandLineBreaks(in: run, text: raw)
        }
    }

    private mutating func expandLineBreaks(in run: AEXMLElement, text: String) throws {
        guard let parent = run.parent else { return }
        let parts = text.components(separatedBy: "\u{2028}")
        guard parts.count > 1 else { return }

        let rPr = run.children.first { DOMScopeResolver.isWord($0, "rPr") }
        var newRuns: [AEXMLElement] = []
        for (idx, part) in parts.enumerated() {
            let newRun = AEXMLElement(name: run.name, value: nil, attributes: run.attributes)
            if let rPr {
                newRun.addChild(deepCopy(rPr))
            }
            if !part.isEmpty {
                let t = newRun.addChild(name: textNodeName(from: run), value: part)
                t.attributes["xml:space"] = "preserve"
            }
            newRuns.append(newRun)
            if idx < parts.count - 1 {
                let brRun = AEXMLElement(name: run.name)
                if let rPr {
                    brRun.addChild(deepCopy(rPr))
                }
                brRun.addChild(name: "w:br")
                newRuns.append(brRun)
            }
        }

        guard let index = parent.children.firstIndex(where: { $0 === run }) else { return }
        let snapshot = parent.children
        for child in snapshot { child.removeFromParent() }
        var rebuilt = snapshot
        rebuilt.replaceSubrange(index..<(index + 1), with: newRuns)
        for child in rebuilt {
            parent.addChild(child)
        }
    }

    private func textNodeName(from run: AEXMLElement) -> String {
        if run.name.hasPrefix("w:") { return "w:t" }
        return "t"
    }

    private mutating func replaceRunWithDrawing(textNode: AEXMLElement, image: InlineImage) throws {
        guard let run = textNode.parent else { return }
        let imageData: Data
        do {
            imageData = try Data(contentsOf: image.url)
        } catch {
            throw DocxTemplateError.ioError("Failed to read image: \(error)")
        }

        let ext = image.url.pathExtension.isEmpty ? "png" : image.url.pathExtension.lowercased()
        let filename = "image\(nextImageId).\(ext)"
        nextImageId += 1
        let mediaPath = "word/media/\(filename)"
        archive.setData(imageData, at: mediaPath)

        let relId = "rId\(relationshipIdCounter)"
        relationshipIdCounter += 1
        try appendRelationship(relId: relId, target: "media/\(filename)")

        // EMUs: 1 mm = 36000 EMUs
        let cx = Int(image.widthMm * 36000)
        let cy = Int(image.heightMm * 36000)
        let docPrId = nextDocPrId
        nextDocPrId += 1

        // Clear run contents and inject a minimal drawing.
        let snapshot = run.children
        for child in snapshot { child.removeFromParent() }

        let drawingXML = """
        <w:drawing>
          <wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
            <wp:extent cx="\(cx)" cy="\(cy)"/>
            <wp:docPr id="\(docPrId)" name="Picture \(docPrId)"/>
            <a:graphic>
              <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic>
                  <pic:nvPicPr>
                    <pic:cNvPr id="0" name="\(filename)"/>
                    <pic:cNvPicPr/>
                  </pic:nvPicPr>
                  <pic:blipFill>
                    <a:blip r:embed="\(relId)"/>
                    <a:stretch><a:fillRect/></a:stretch>
                  </pic:blipFill>
                  <pic:spPr>
                    <a:xfrm>
                      <a:off x="0" y="0"/>
                      <a:ext cx="\(cx)" cy="\(cy)"/>
                    </a:xfrm>
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                  </pic:spPr>
                </pic:pic>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing>
        """
        // Parse fragment and attach.
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        if let fragment = try? AEXMLDocument(xml: "<root>\(drawingXML)</root>", options: options) {
            for child in fragment.root.children {
                run.addChild(deepCopy(child))
            }
        }
    }

    /// Injects rich text runs in place of a text node.
    static func richTextRunsXML(_ runs: [RichTextRun]) -> [AEXMLElement] {
        runs.map { run in
            let r = AEXMLElement(name: "w:r")
            if run.bold || run.italic || run.underline {
                let rPr = r.addChild(name: "w:rPr")
                if run.bold { rPr.addChild(name: "w:b") }
                if run.italic { rPr.addChild(name: "w:i") }
                if run.underline { rPr.addChild(name: "w:u", value: nil, attributes: ["w:val": "single"]) }
            }
            let t = r.addChild(name: "w:t", value: run.text)
            if run.text.contains(" ") {
                t.attributes["xml:space"] = "preserve"
            }
            return r
        }
    }

    private mutating func appendRelationship(relId: String, target: String) throws {
        let relsPath = "word/_rels/document.xml.rels"
        let relsData = archive.data(at: relsPath) ?? Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """.utf8)

        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        let doc = try AEXMLDocument(xml: relsData, options: options)
        doc.root.addChild(
            name: "Relationship",
            value: nil,
            attributes: [
                "Id": relId,
                "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                "Target": target,
            ]
        )
        guard let data = doc.xmlCompact.data(using: .utf8) else {
            throw DocxTemplateError.ioError("Failed to serialize relationships")
        }
        archive.setData(data, at: relsPath)

        // Ensure content type for media extension
        try ensureContentType(for: (target as NSString).pathExtension)
    }

    private mutating func ensureContentType(for ext: String) throws {
        let path = "[Content_Types].xml"
        guard var data = archive.data(at: path) else { return }
        let lower = ext.lowercased()
        let mime: String
        switch lower {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "bmp": mime = "image/bmp"
        case "emf": mime = "image/x-emf"
        default: mime = "image/\(lower)"
        }
        if let xml = String(data: data, encoding: .utf8),
           !xml.contains("Extension=\"\(lower)\"") {
            let insertion = "<Default Extension=\"\(lower)\" ContentType=\"\(mime)\"/>"
            if let range = xml.range(of: "</Types>") {
                var updated = xml
                updated.replaceSubrange(range, with: insertion + "</Types>")
                data = Data(updated.utf8)
                archive.setData(data, at: path)
            }
        }
    }

    private func deepCopy(_ element: AEXMLElement) -> AEXMLElement {
        let copy = AEXMLElement(name: element.name, value: element.value, attributes: element.attributes)
        for child in element.children {
            copy.addChild(deepCopy(child))
        }
        return copy
    }
}

/// Escapes text for WordprocessingML text nodes (AEXML also escapes on write).
enum XMLEscaper {
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
