import Foundation

/// Lexical tokens produced from normalized Word XML text content.
enum TemplateToken: Equatable {
    case literal(String)
    /// `{{ expression | filter }}` or `{%= expression %}` style variable.
    case variable(expression: String, filters: [FilterCall])
    /// Opening block: `{%tr for x in y %}`, `{#items}`, `{%p if cond %}`, `{^items}` (inverted).
    case openBlock(OpenBlock)
    /// `{% else %}` / `{%tr else %}` etc.
    case elseBlock
    /// `{% end* %}` / `{/items}`
    case closeBlock(tag: String?)
}

struct FilterCall: Equatable {
    var name: String
    var arguments: [String]
}

enum BlockKind: Equatable {
    case `for`(item: String, collection: String)
    case `if`(condition: String)
    case unless(condition: String) // docxtemplater `{^`
}

enum BlockScope: String, Equatable {
    case tr   // table row
    case tc   // table cell
    case p    // paragraph
    case r    // run
    case auto // inferred from DOM
}

struct OpenBlock: Equatable {
    var kind: BlockKind
    var scope: BlockScope
    /// Raw tag body for error messages / close matching.
    var raw: String
}

/// Tokenizes template source text supporting both docxtpl and docxtemplater syntax.
struct TemplateLexer {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    func tokenize() throws -> [TemplateToken] {
        var tokens: [TemplateToken] = []
        var i = source.startIndex

        while i < source.endIndex {
            if let tagStart = findTagStart(from: i) {
                if tagStart > i {
                    tokens.append(.literal(String(source[i..<tagStart])))
                }
                let (token, next) = try parseTag(from: tagStart)
                tokens.append(token)
                i = next
            } else {
                tokens.append(.literal(String(source[i...])))
                break
            }
        }
        return mergeAdjacentLiterals(tokens)
    }

    // MARK: - Tag detection

    private func findTagStart(from index: String.Index) -> String.Index? {
        var i = index
        while i < source.endIndex {
            if source[i] == "{" {
                let next = source.index(after: i)
                if next < source.endIndex {
                    let c = source[next]
                    if c == "{" || c == "%" || c == "#" || c == "/" || c == "^" {
                        return i
                    }
                }
            }
            i = source.index(after: i)
        }
        return nil
    }

    private func parseTag(from start: String.Index) throws -> (TemplateToken, String.Index) {
        let afterBrace = source.index(after: start)
        guard afterBrace < source.endIndex else {
            throw DocxTemplateError.invalidExpression("Unterminated tag at end of input")
        }
        let sigil = source[afterBrace]

        switch sigil {
        case "{":
            return try parseMustacheVariable(from: start)
        case "%":
            return try parsePercentTag(from: start)
        case "#", "^":
            return try parseDocxtemplaterOpen(from: start, inverted: sigil == "^")
        case "/":
            return try parseDocxtemplaterClose(from: start)
        default:
            throw DocxTemplateError.invalidExpression("Unknown tag sigil")
        }
    }

    // MARK: - {{ var | filter }}

    private func parseMustacheVariable(from start: String.Index) throws -> (TemplateToken, String.Index) {
        guard let end = findClosing(from: start, open: "{{", close: "}}") else {
            throw DocxTemplateError.invalidExpression("Unterminated {{ tag")
        }
        let contentStart = source.index(start, offsetBy: 2)
        let contentEnd = source.index(end, offsetBy: -2)
        let raw = source[contentStart..<contentEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Triple-style escaped content already handled; support filters via `|`
        let (expr, filters) = parseFilters(raw)
        let next = end
        return (.variable(expression: expr, filters: filters), next)
    }

    // MARK: - {% ... %}

    private func parsePercentTag(from start: String.Index) throws -> (TemplateToken, String.Index) {
        guard let end = findClosing(from: start, open: "{%", close: "%}") else {
            throw DocxTemplateError.invalidExpression("Unterminated {% tag")
        }
        let contentStart = source.index(start, offsetBy: 2)
        let contentEnd = source.index(end, offsetBy: -2)
        let raw = String(source[contentStart..<contentEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let token = try interpretPercentBody(raw)
        return (token, end)
    }

    private func interpretPercentBody(_ raw: String) throws -> TemplateToken {
        let lower = raw.lowercased()

        // else
        if lower == "else" || lower.hasSuffix(" else") && lower.split(separator: " ").last == "else" {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count == 1 || (parts.count == 2 && ["tr", "tc", "p", "r"].contains(parts[0].lowercased())) {
                return .elseBlock
            }
        }

        // end / endfor / endif / endtr ...
        if lower.hasPrefix("end") {
            return .closeBlock(tag: raw)
        }

        // Scope prefix: tr/tc/p/r
        var scope: BlockScope = .auto
        var body = raw
        let scopePrefixes: [(String, BlockScope)] = [
            ("tr ", .tr), ("tc ", .tc), ("p ", .p), ("r ", .r),
        ]
        for (prefix, s) in scopePrefixes {
            if lower.hasPrefix(prefix) {
                scope = s
                body = String(raw.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let bodyLower = body.lowercased()

        if bodyLower.hasPrefix("for ") {
            // for item in collection
            let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // ["for", item, "in", collection...]
            guard parts.count >= 4, parts[0].lowercased() == "for", parts[2].lowercased() == "in" else {
                throw DocxTemplateError.invalidExpression("Invalid for tag: \(raw)")
            }
            let item = parts[1]
            let collection = parts[3...].joined(separator: " ")
            return .openBlock(OpenBlock(
                kind: .for(item: item, collection: collection),
                scope: scope,
                raw: raw
            ))
        }

        if bodyLower.hasPrefix("if ") {
            let condition = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return .openBlock(OpenBlock(kind: .if(condition: condition), scope: scope, raw: raw))
        }

        // `{%= expression %}` or `{% expression %}` as variable output
        var exprBody = body
        if exprBody.hasPrefix("=") {
            exprBody = String(exprBody.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let (expr, filters) = parseFilters(exprBody)
        return .variable(expression: expr, filters: filters)
    }

    // MARK: - {#items} / {^items}

    private func parseDocxtemplaterOpen(
        from start: String.Index,
        inverted: Bool
    ) throws -> (TemplateToken, String.Index) {
        guard let end = findClosing(from: start, open: "{", close: "}") else {
            throw DocxTemplateError.invalidExpression("Unterminated block tag")
        }
        // Content between `{#` / `{^` and `}`
        let contentStart = source.index(start, offsetBy: 2)
        let contentEnd = source.index(before: end)
        let name = String(source[contentStart..<contentEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DocxTemplateError.invalidExpression("Empty block name")
        }

        let kind: BlockKind = inverted
            ? .unless(condition: name)
            : .for(item: "", collection: name) // empty item => use element itself as scope
        let token = TemplateToken.openBlock(OpenBlock(kind: kind, scope: .auto, raw: name))
        return (token, end)
    }

    private func parseDocxtemplaterClose(from start: String.Index) throws -> (TemplateToken, String.Index) {
        guard let end = findClosing(from: start, open: "{", close: "}") else {
            throw DocxTemplateError.invalidExpression("Unterminated close tag")
        }
        let contentStart = source.index(start, offsetBy: 2) // past `{/`
        let contentEnd = source.index(before: end)
        let name = String(source[contentStart..<contentEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.closeBlock(tag: name.isEmpty ? nil : name), end)
    }

    // MARK: - Helpers

    private func findClosing(from start: String.Index, open: String, close: String) -> String.Index? {
        guard source[start...].hasPrefix(open) else { return nil }
        var i = source.index(start, offsetBy: open.count)
        while i < source.endIndex {
            if source[i...].hasPrefix(close) {
                return source.index(i, offsetBy: close.count)
            }
            i = source.index(after: i)
        }
        return nil
    }

    private func parseFilters(_ raw: Substring) -> (String, [FilterCall]) {
        parseFilters(String(raw))
    }

    private func parseFilters(_ raw: String) -> (String, [FilterCall]) {
        // Split on `|` but not inside parentheses / quotes (simple scan).
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuote: Character?
        for ch in raw {
            if let q = inQuote {
                current.append(ch)
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                current.append(ch)
                continue
            }
            if ch == "(" { depth += 1; current.append(ch); continue }
            if ch == ")" { depth = max(0, depth - 1); current.append(ch); continue }
            if ch == "|", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty || !parts.isEmpty {
            parts.append(trimmed)
        }
        guard let first = parts.first, !first.isEmpty else {
            return ("", [])
        }
        let filters = parts.dropFirst().compactMap { parseFilterCall($0) }
        return (first, filters)
    }

    private func parseFilterCall(_ raw: String) -> FilterCall? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // name or name(args) or :drop(p) Carbone style
        var name = trimmed
        var args: [String] = []
        if let open = trimmed.firstIndex(of: "("),
           trimmed.hasSuffix(")"),
           open < trimmed.index(before: trimmed.endIndex) {
            name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            args = splitArgs(inner)
        }
        // Carbone `:drop(p)` — keep leading colon in name if present
        return FilterCall(name: name, arguments: args)
    }

    private func splitArgs(_ inner: String) -> [String] {
        inner.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
    }

    private func mergeAdjacentLiterals(_ tokens: [TemplateToken]) -> [TemplateToken] {
        var result: [TemplateToken] = []
        for token in tokens {
            if case .literal(let text) = token, text.isEmpty { continue }
            if case .literal(let a) = token,
               case .literal(let b)? = result.last {
                result[result.count - 1] = .literal(b + a)
            } else {
                result.append(token)
            }
        }
        return result
    }
}
