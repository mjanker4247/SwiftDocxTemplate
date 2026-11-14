import Foundation
import AEXML

/// Evaluates block constructs by cloning AEXMLElement subtrees for loops
/// and conditionally keeping/removing hosts for if/unless.
struct BlockEvaluator {
    var context: ScopeContext

    init(context: ScopeContext) {
        self.context = context
    }

    /// Renders a sequence of AST nodes into a flat string (for in-run substitution).
    mutating func renderText(_ nodes: [TemplateNode]) throws -> String {
        var output = ""
        for node in nodes {
            switch node {
            case .literal(let text):
                output += text
            case .variable(let expression, let filters):
                let evaluator = ExpressionEvaluator(context: context)
                var value = try evaluator.evaluate(expression)
                value = try evaluator.applyFilters(filters, to: value)
                if case .object(let dict) = value, dict["__drop__"] != nil {
                    // Drop markers are handled at the DOM layer; emit empty here.
                    continue
                }
                if case .image = value { continue }
                if case .richText = value { continue }
                output += value.stringValue ?? ""
            case .block(let block):
                output += try renderBlockAsText(block)
            }
        }
        return output
    }

    private mutating func renderBlockAsText(_ block: BlockNode) throws -> String {
        switch block.open.kind {
        case .for(let item, let collection):
            let value = context.resolve(path: collection)
            guard case .array(let items) = value else {
                return try renderElse(block)
            }
            var combined = ""
            for element in items {
                if item.isEmpty {
                    context.push(element)
                } else {
                    context.pushBinding(name: item, value: element)
                }
                defer { context.pop() }
                combined += try renderText(block.body)
            }
            return combined

        case .if(let condition):
            let ok = try ExpressionEvaluator(context: context).evaluateTruthy(condition)
            return try renderText(ok ? block.body : block.elseBody)

        case .unless(let condition):
            let value = context.resolve(path: condition)
            let inverted = !value.isTruthy
            return try renderText(inverted ? block.body : block.elseBody)
        }
    }

    private mutating func renderElse(_ block: BlockNode) throws -> String {
        try renderText(block.elseBody)
    }

    // MARK: - DOM cloning

    /// Clones `host` once per array element and rewrites its inner template text.
    mutating func expandLoop(
        host: AEXMLElement,
        itemName: String,
        collectionPath: String,
        openRaw: String,
        closeRaw: String?
    ) throws {
        guard let parent = host.parent else { return }
        let collection = context.resolve(path: collectionPath)
        guard case .array(let items) = collection else {
            host.removeFromParent()
            return
        }

        guard let hostIndex = parent.children.firstIndex(where: { $0 === host }) else { return }

        var clones: [AEXMLElement] = []
        for element in items {
            let clone = deepCopy(host)
            if itemName.isEmpty {
                context.push(element)
            } else {
                context.pushBinding(name: itemName, value: element)
            }
            defer { context.pop() }
            try rewriteElementText(clone, removingOpen: openRaw, close: closeRaw)
            clones.append(clone)
        }

        replaceChildren(of: parent, replacing: hostIndex, count: 1, with: clones)
    }

    /// Rebuilds a parent's child list because AEXML exposes `children` as `internal(set)`.
    private func replaceChildren(
        of parent: AEXMLElement,
        replacing index: Int,
        count: Int,
        with newElements: [AEXMLElement]
    ) {
        let snapshot = parent.children
        for child in snapshot {
            child.removeFromParent()
        }
        var rebuilt = snapshot
        let range = index..<(index + count)
        rebuilt.replaceSubrange(range, with: newElements)
        for child in rebuilt {
            parent.addChild(child)
        }
    }

    /// Conditionally keeps or removes a host element for if / unless / drop.
    mutating func applyConditional(
        host: AEXMLElement,
        keep: Bool,
        openRaw: String,
        closeRaw: String?
    ) throws {
        if keep {
            try rewriteElementText(host, removingOpen: openRaw, close: closeRaw)
        } else {
            host.removeFromParent()
        }
    }

    /// Evaluates variables inside an element's text runs (after blocks removed).
    mutating func rewriteElementText(
        _ element: AEXMLElement,
        removingOpen openRaw: String? = nil,
        close closeRaw: String? = nil
    ) throws {
        for child in element.children {
            try rewriteElementText(child, removingOpen: openRaw, close: closeRaw)
        }
        guard DOMScopeResolver.isWord(element, "t") else { return }
        var text = element.value ?? ""
        if let openRaw {
            text = stripTag(containing: openRaw, from: text)
        }
        if let closeRaw {
            text = stripCloseTag(named: closeRaw, from: text)
        }
        // Replace remaining mustache / percent variables.
        text = try substituteVariables(in: text)
        element.value = text
        if text.contains(" ") {
            element.attributes["xml:space"] = "preserve"
        }
    }

    private func stripTag(containing raw: String, from text: String) -> String {
        // Remove `{%...raw...%}`, `{#raw}`, etc. occurrences loosely.
        var result = text
        let patterns = [
            "{%" + raw + "%}",
            "{% " + raw + " %}",
            "{#" + raw + "}",
            "{^" + raw + "}",
        ]
        for p in patterns {
            result = result.replacingOccurrences(of: p, with: "")
        }
        // Also remove any {%...%} that equals raw after trim
        if let regex = try? NSRegularExpression(pattern: "\\{%(?:tr |tc |p |r )?\(NSRegularExpression.escapedPattern(for: raw))%\\}") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    private func stripCloseTag(named raw: String, from text: String) -> String {
        var result = text
        let patterns = [
            "{/" + raw + "}",
            "{% end %}",
            "{%end%}",
            "{% endfor %}",
            "{% endif %}",
            "{% endtr %}",
            "{% endtc %}",
            "{% endp %}",
            "{% endr %}",
            "{%" + raw + "%}",
        ]
        for p in patterns {
            result = result.replacingOccurrences(of: p, with: "")
        }
        return result
    }

    private mutating func substituteVariables(in text: String) throws -> String {
        let tokens = try TemplateLexer(text).tokenize()
        // Only render non-block tokens; blocks should already be handled at DOM level.
        let safe = tokens.compactMap { token -> TemplateNode? in
            switch token {
            case .literal(let s): return .literal(s)
            case .variable(let e, let f): return .variable(expression: e, filters: f)
            default: return .literal("") // strip residual block tags
            }
        }
        return try renderText(safe)
    }

    func deepCopy(_ element: AEXMLElement) -> AEXMLElement {
        let copy = AEXMLElement(
            name: element.name,
            value: element.value,
            attributes: element.attributes
        )
        for child in element.children {
            copy.addChild(deepCopy(child))
        }
        return copy
    }
}
