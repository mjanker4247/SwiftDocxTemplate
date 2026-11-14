import Foundation
import AEXML

/// Orchestrates the 5-stage rendering pipeline for a single Word XML part
/// (`document.xml`, `header*.xml`, `footer*.xml`).
struct DocumentPipeline {
    var context: ScopeContext
    var mediaInjector: MediaInjector

    init(context: ScopeContext, archive: DocxArchive) {
        self.context = context
        self.mediaInjector = MediaInjector(archive: archive)
    }

    var archive: DocxArchive {
        get { mediaInjector.archive }
        set { mediaInjector.archive = newValue }
    }

    mutating func render(xml data: Data) throws -> Data {
        // Stage 1 — normalize runs / heal delimiters
        let normalized = try RunNormalizer.normalize(xml: data)

        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        options.documentHeader.standalone = "yes"
        let document: AEXMLDocument
        do {
            document = try AEXMLDocument(xml: normalized, options: options)
        } catch {
            throw DocxTemplateError.malformedXML(String(describing: error))
        }

        // Stages 2–4 — parse tags found in text, evaluate blocks against the DOM
        try processBlocks(in: document.root)
        try substituteAllVariables(in: document.root)
        try applyDropFilters(in: document.root)

        guard let serialized = document.xmlCompact.data(using: .utf8) else {
            throw DocxTemplateError.malformedXML("Failed to serialize rendered XML")
        }

        // Stage 5 — media / rich text / xml:space
        return try mediaInjector.process(xml: serialized, context: context)
    }

    // MARK: - Block processing

    /// Finds open-block tags in document order and expands/removes their host elements.
    private mutating func processBlocks(in root: AEXMLElement) throws {
        // Iterate until no more open-block tags remain (handles nested loops by outer-first).
        var safety = 0
        while safety < 1000 {
            safety += 1
            guard let match = findFirstOpenBlock(in: root) else { break }
            try evaluateMatchedBlock(match)
        }
    }

    private struct BlockMatch {
        var open: OpenBlock
        var openRun: AEXMLElement
        var closeRun: AEXMLElement?
        var closeTag: String?
        var host: AEXMLElement
        var fullTextSnippet: String
    }

    private func findFirstOpenBlock(in root: AEXMLElement) -> BlockMatch? {
        let texts = collectTextRuns(in: root)
        let joined = texts.map(\.text).joined()
        guard let tokens = try? TemplateLexer(joined).tokenize() else { return nil }

        // Map character offsets back to runs.
        var openToken: OpenBlock?
        var openOffset: Int?
        var closeOffset: Int?
        var closeTag: String?
        var depth = 0
        var cursor = 0

        for token in tokens {
            switch token {
            case .literal(let s):
                cursor += s.count
            case .variable(let e, let f):
                // Approximate token width from reconstruction
                let width = reconstructedVariableWidth(e, f)
                cursor += width
            case .openBlock(let open):
                if openToken == nil {
                    openToken = open
                    openOffset = cursor
                }
                depth += 1
                cursor += reconstructedOpenWidth(open)
            case .elseBlock:
                cursor += 10 // "{% else %}" approx — only used for depth tracking in joined scan
            case .closeBlock(let tag):
                depth -= 1
                if depth == 0, openToken != nil, closeOffset == nil {
                    closeOffset = cursor
                    closeTag = tag
                }
                cursor += reconstructedCloseWidth(tag)
            }
            if openToken != nil, closeOffset != nil { break }
        }

        guard let open = openToken, let start = openOffset else { return nil }

        guard let openTextRun = runAt(characterOffset: start, in: texts) ?? texts.first else {
            return nil
        }
        let closeRun: AEXMLElement?
        if let closeOffset {
            closeRun = runAt(characterOffset: closeOffset, in: texts)?.run
        } else {
            closeRun = nil
        }

        let host = DOMScopeResolver.resolveHost(for: open.scope, from: openTextRun.run)
        return BlockMatch(
            open: open,
            openRun: openTextRun.run,
            closeRun: closeRun,
            closeTag: closeTag,
            host: host,
            fullTextSnippet: joined
        )
    }

    private mutating func evaluateMatchedBlock(_ match: BlockMatch) throws {
        var evaluator = BlockEvaluator(context: context)
        let closeRaw = match.closeTag ?? "end"

        switch match.open.kind {
        case .for(let item, let collection):
            try evaluator.expandLoop(
                host: match.host,
                itemName: item,
                collectionPath: collection,
                openRaw: match.open.raw,
                closeRaw: closeRaw
            )
            context = evaluator.context

        case .if(let condition):
            let keep = try ExpressionEvaluator(context: context).evaluateTruthy(condition)
            try evaluator.applyConditional(
                host: match.host,
                keep: keep,
                openRaw: match.open.raw,
                closeRaw: closeRaw
            )
            context = evaluator.context

        case .unless(let condition):
            let value = context.resolve(path: condition)
            let keep = !value.isTruthy
            try evaluator.applyConditional(
                host: match.host,
                keep: keep,
                openRaw: match.open.raw,
                closeRaw: closeRaw
            )
            context = evaluator.context
        }
    }

    // MARK: - Variable substitution

    private mutating func substituteAllVariables(in root: AEXMLElement) throws {
        let runs = collectTextRuns(in: root)
        // Process each paragraph independently so we don't cross block boundaries incorrectly.
        var paragraphs: [AEXMLElement] = []
        collectParagraphs(root, into: &paragraphs)
        if paragraphs.isEmpty {
            try substituteRuns(runs)
            return
        }
        for paragraph in paragraphs {
            try substituteRuns(collectTextRuns(in: paragraph))
        }
    }

    private mutating func substituteRuns(_ runs: [TextRun]) throws {
        guard !runs.isEmpty else { return }
        // Join paragraph text, tokenize, render, then write back into the first run and clear others.
        let joined = runs.map(\.text).joined()
        guard joined.contains("{{") || joined.contains("{%") else {
            // Still may have single-run variables already isolated.
            for item in runs {
                if item.text.contains("{{") || item.text.contains("{%") {
                    var evaluator = BlockEvaluator(context: context)
                    var parser = try TemplateParser(source: item.text)
                    let rendered = try evaluator.renderText(parser.parse())
                    setText(on: item.run, rendered)
                    context = evaluator.context
                }
            }
            return
        }

        var parser = try TemplateParser(source: joined)
        let nodes = try parser.parse()
        // If nodes contain blocks, leave them — block pass should have handled them.
        let hasBlocks = nodes.contains { if case .block = $0 { return true }; return false }
        if hasBlocks { return }

        var evaluator = BlockEvaluator(context: context)
        let rendered = try evaluator.renderText(nodes)
        context = evaluator.context

        // Also handle image / richText markers by resolving remaining variable nodes specially.
        if nodes.count == 1, case .variable(let expr, let filters) = nodes[0] {
            let exprEval = ExpressionEvaluator(context: context)
            var value = try exprEval.evaluate(expr)
            value = try exprEval.applyFilters(filters, to: value)
            if case .image = value {
                setText(on: runs[0].run, "<<IMAGE:\(expr)>>")
                for extra in runs.dropFirst() { setText(on: extra.run, "") }
                return
            }
            if case .richText(let richRuns) = value {
                try replaceWithRichText(runs: runs, richRuns: richRuns)
                return
            }
            if case .object(let dict) = value, case .string(let target)? = dict["__drop__"] {
                // Mark nearest ancestor for drop.
                markDrop(from: runs[0].run, target: target)
                for item in runs { setText(on: item.run, "") }
                return
            }
        }

        setText(on: runs[0].run, rendered)
        for extra in runs.dropFirst() {
            setText(on: extra.run, "")
        }
    }

    private func replaceWithRichText(
        runs: [TextRun],
        richRuns: [RichTextRun]
    ) throws {
        guard let first = runs.first?.run, let parent = first.parent else { return }
        let newRuns = MediaInjector.richTextRunsXML(richRuns)
        let snapshot = parent.children
        guard let index = snapshot.firstIndex(where: { $0 === first }) else { return }
        // Remove the original simple text runs that belonged to this substitution.
        let runSet = Set(runs.map { ObjectIdentifier($0.run) })
        for child in snapshot where runSet.contains(ObjectIdentifier(child)) {
            child.removeFromParent()
        }
        // Re-collect and insert rich runs at index.
        let afterRemove = parent.children
        for child in afterRemove { child.removeFromParent() }
        var rebuilt = afterRemove
        // Find insertion point relative to remaining siblings — use original index clamped.
        let insertAt = min(index, rebuilt.count)
        rebuilt.insert(contentsOf: newRuns, at: insertAt)
        for child in rebuilt {
            parent.addChild(child)
        }
    }

    private func markDrop(from run: AEXMLElement, target: String) {
        let host: AEXMLElement
        switch target {
        case "tr": host = DOMScopeResolver.ancestor(named: "tr", from: run) ?? run
        case "tc": host = DOMScopeResolver.ancestor(named: "tc", from: run) ?? run
        default: host = DOMScopeResolver.ancestor(named: "p", from: run) ?? run
        }
        host.attributes["data-swiftdocx-drop"] = "true"
    }

    private func applyDropFilters(in root: AEXMLElement) throws {
        let marked = findMarkedDrops(in: root)
        for el in marked {
            el.removeFromParent()
        }
    }

    private func findMarkedDrops(in element: AEXMLElement) -> [AEXMLElement] {
        var result: [AEXMLElement] = []
        if element.attributes["data-swiftdocx-drop"] == "true" {
            result.append(element)
        }
        for child in element.children {
            result.append(contentsOf: findMarkedDrops(in: child))
        }
        return result
    }

    // MARK: - Text run helpers

    private struct TextRun {
        var run: AEXMLElement
        var text: String
    }

    private func collectTextRuns(in element: AEXMLElement) -> [TextRun] {
        var result: [TextRun] = []
        func walk(_ el: AEXMLElement) {
            if DOMScopeResolver.isWord(el, "r") {
                let text = el.children
                    .filter { DOMScopeResolver.isWord($0, "t") }
                    .map { $0.string }
                    .joined()
                result.append(TextRun(run: el, text: text))
                return
            }
            for child in el.children { walk(child) }
        }
        walk(element)
        return result
    }

    private func collectParagraphs(_ element: AEXMLElement, into result: inout [AEXMLElement]) {
        if DOMScopeResolver.isWord(element, "p") {
            result.append(element)
            return
        }
        for child in element.children {
            collectParagraphs(child, into: &result)
        }
    }

    private func runAt(characterOffset: Int, in runs: [TextRun]) -> TextRun? {
        var cursor = 0
        for run in runs {
            let end = cursor + run.text.count
            if characterOffset < end || (characterOffset == cursor && run.text.isEmpty == false) {
                return run
            }
            if characterOffset == cursor {
                return run
            }
            cursor = end
        }
        return runs.last
    }

    private func setText(on run: AEXMLElement, _ text: String) {
        let textNodes = run.children.filter { DOMScopeResolver.isWord($0, "t") }
        if let first = textNodes.first {
            first.value = text
            if text.contains(" ") || text.hasPrefix(" ") || text.hasSuffix(" ") {
                first.attributes["xml:space"] = "preserve"
            }
            for extra in textNodes.dropFirst() {
                extra.removeFromParent()
            }
        } else if !text.isEmpty {
            let name = run.name.hasPrefix("w:") ? "w:t" : "t"
            let t = run.addChild(name: name, value: text)
            t.attributes["xml:space"] = "preserve"
        }
    }

    private func reconstructedVariableWidth(_ expr: String, _ filters: [FilterCall]) -> Int {
        var s = "{{ \(expr)"
        for f in filters {
            s += " | \(f.name)"
            if !f.arguments.isEmpty {
                s += "(\(f.arguments.joined(separator: ",")))"
            }
        }
        s += " }}"
        return s.count
    }

    private func reconstructedOpenWidth(_ open: OpenBlock) -> Int {
        switch open.scope {
        case .auto:
            // docxtemplater style
            switch open.kind {
            case .for(_, let c) where open.raw == c || open.raw.isEmpty:
                return "{#\(open.raw)}".count
            case .unless:
                return "{^\(open.raw)}".count
            default:
                return "{% \(open.raw) %}".count
            }
        default:
            return "{%\(open.scope.rawValue) \(open.raw) %}".count
        }
    }

    private func reconstructedCloseWidth(_ tag: String?) -> Int {
        if let tag, !tag.isEmpty {
            if tag.hasPrefix("end") {
                return "{% \(tag) %}".count
            }
            return "{/\(tag)}".count
        }
        return "{% end %}".count
    }
}

/// Collects undeclared variable names from all XML parts.
enum UndeclaredVariableScanner {
    static func scan(archive: DocxArchive) throws -> Set<String> {
        var declared = Set<String>()
        var paths = ["word/document.xml"]
        paths.append(contentsOf: archive.headerFooterPaths)

        for path in paths {
            guard let data = archive.data(at: path) else { continue }
            let normalized = try RunNormalizer.normalize(xml: data)
            let texts = try extractAllText(from: normalized)
            for text in texts {
                guard text.contains("{{") || text.contains("{%") || text.contains("{#") || text.contains("{^") else {
                    continue
                }
                if let tokens = try? TemplateLexer(text).tokenize() {
                    var parser = TemplateParser(tokens: tokens)
                    if let nodes = try? parser.parse() {
                        declared.formUnion(TemplateAST.collectVariables(in: nodes))
                    }
                }
            }
        }
        return declared.filter { !$0.isEmpty && $0 != "." }
    }

    private static func extractAllText(from data: Data) throws -> [String] {
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false
        let doc = try AEXMLDocument(xml: data, options: options)
        var paragraphs: [String] = []
        func walk(_ el: AEXMLElement, buffer: inout String) {
            if DOMScopeResolver.isWord(el, "p") {
                var local = ""
                collectRunText(el, into: &local)
                paragraphs.append(local)
                return
            }
            for child in el.children {
                walk(child, buffer: &buffer)
            }
        }
        func collectRunText(_ el: AEXMLElement, into buffer: inout String) {
            if DOMScopeResolver.isWord(el, "t") {
                buffer += el.string
                return
            }
            for child in el.children {
                collectRunText(child, into: &buffer)
            }
        }
        var unused = ""
        walk(doc.root, buffer: &unused)
        return paragraphs
    }
}
