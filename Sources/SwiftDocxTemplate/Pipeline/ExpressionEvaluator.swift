import Foundation

/// Evaluates template expressions, comparisons, boolean logic, and pipe filters.
struct ExpressionEvaluator {
    var context: ScopeContext

    init(context: ScopeContext) {
        self.context = context
    }

    func evaluate(_ expression: String) throws -> TemplateValue {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .null }
        return try evaluateBooleanOrComparison(trimmed)
    }

    func evaluateString(_ expression: String, filters: [FilterCall] = []) throws -> String {
        var value = try evaluate(expression)
        value = try applyFilters(filters, to: value)
        return value.stringValue ?? ""
    }

    func evaluateTruthy(_ expression: String) throws -> Bool {
        try evaluate(expression).isTruthy
    }

    // MARK: - Boolean / comparison

    private func evaluateBooleanOrComparison(_ expr: String) throws -> TemplateValue {
        // or
        if let parts = splitOutside(expr, operator: " or ") {
            let left = try evaluateBooleanOrComparison(parts.0)
            if left.isTruthy { return left }
            return try evaluateBooleanOrComparison(parts.1)
        }
        // and
        if let parts = splitOutside(expr, operator: " and ") {
            let left = try evaluateBooleanOrComparison(parts.0)
            if !left.isTruthy { return .bool(false) }
            return try evaluateBooleanOrComparison(parts.1)
        }
        // not
        if expr.lowercased().hasPrefix("not ") {
            let inner = String(expr.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return .bool(!((try evaluateBooleanOrComparison(inner)).isTruthy))
        }
        // comparisons
        for op in ["!=", "<>", "<=", ">=", "==", "=", "<", ">"] {
            if let parts = splitOutside(expr, operator: op) {
                let left = try evaluatePrimary(parts.0.trimmingCharacters(in: .whitespaces))
                let right = try evaluatePrimary(parts.1.trimmingCharacters(in: .whitespaces))
                return .bool(compare(left, right, op: op))
            }
        }
        return try evaluatePrimary(expr)
    }

    private func evaluatePrimary(_ expr: String) throws -> TemplateValue {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" || trimmed == "nil" || trimmed == "none" { return .null }
        if trimmed == "." { return context.current }
        if let num = Int(trimmed) { return .int(num) }
        if let num = Double(trimmed), trimmed.contains(".") { return .double(num) }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(String(trimmed.dropFirst().dropLast()))
        }
        return context.resolve(path: trimmed)
    }

    private func compare(_ left: TemplateValue, _ right: TemplateValue, op: String) -> Bool {
        switch op {
        case "==", "=":
            return stringify(left) == stringify(right)
        case "!=", "<>":
            return stringify(left) != stringify(right)
        case "<":
            return numeric(left) < numeric(right)
        case ">":
            return numeric(left) > numeric(right)
        case "<=":
            return numeric(left) <= numeric(right)
        case ">=":
            return numeric(left) >= numeric(right)
        default:
            return false
        }
    }

    private func stringify(_ value: TemplateValue) -> String {
        value.stringValue ?? ""
    }

    private func numeric(_ value: TemplateValue) -> Double {
        switch value {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .string(let v): return Double(v) ?? 0
        case .bool(let v): return v ? 1 : 0
        default: return 0
        }
    }

    // MARK: - Filters

    func applyFilters(_ filters: [FilterCall], to value: TemplateValue) throws -> TemplateValue {
        var current = value
        for filter in filters {
            current = try applyFilter(filter, to: current)
        }
        return current
    }

    private func applyFilter(_ filter: FilterCall, to value: TemplateValue) throws -> TemplateValue {
        let name = filter.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        switch name {
        case "upper":
            return .string((value.stringValue ?? "").uppercased())
        case "lower":
            return .string((value.stringValue ?? "").lowercased())
        case "capitalize":
            let s = value.stringValue ?? ""
            return .string(s.prefix(1).uppercased() + s.dropFirst())
        case "default":
            if value.isTruthy, value.stringValue?.isEmpty == false {
                return value
            }
            return .string(filter.arguments.first ?? "")
        case "number":
            let format = filter.arguments.first ?? "%.2f"
            let n = numeric(value)
            return .string(String(format: format, n))
        case "date":
            let format = filter.arguments.first ?? "yyyy-MM-dd"
            let date: Date
            switch value {
            case .date(let d):
                date = d
            case .string(let s):
                let iso = ISO8601DateFormatter()
                guard let parsed = iso.date(from: s) else { return .string(s) }
                date = parsed
            default:
                return value
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return .string(formatter.string(from: date))
        case "linebreaks":
            let s = value.stringValue ?? ""
            // Represent line breaks as a special marker consumed by MediaInjector.
            return .string(s.replacingOccurrences(of: "\n", with: "\u{2028}"))
        case "drop":
            // Carbone `:drop(p|tr|tc)` — return a sentinel object the block/media stage interprets.
            let target = filter.arguments.first ?? "p"
            return .object(["__drop__": .string(target)])
        default:
            throw DocxTemplateError.unsupportedFilter(filter.name)
        }
    }

    // MARK: - Split helper

    private func splitOutside(_ expr: String, operator op: String) -> (String, String)? {
        var depth = 0
        var inQuote: Character?
        var i = expr.startIndex
        while i < expr.endIndex {
            let ch = expr[i]
            if let q = inQuote {
                if ch == q { inQuote = nil }
                i = expr.index(after: i)
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                i = expr.index(after: i)
                continue
            }
            if ch == "(" { depth += 1; i = expr.index(after: i); continue }
            if ch == ")" { depth = max(0, depth - 1); i = expr.index(after: i); continue }
            if depth == 0, expr[i...].hasPrefix(op) {
                let left = String(expr[..<i])
                let right = String(expr[expr.index(i, offsetBy: op.count)...])
                return (left, right)
            }
            i = expr.index(after: i)
        }
        return nil
    }
}

/// Nested scope for loops and object path resolution.
struct ScopeContext: Equatable {
    private var stack: [TemplateValue]

    init(root: [String: TemplateValue]) {
        self.stack = [.object(root)]
    }

    init(value: TemplateValue) {
        self.stack = [value]
    }

    var current: TemplateValue {
        stack.last ?? .null
    }

    mutating func push(_ value: TemplateValue) {
        stack.append(value)
    }

    mutating func pop() {
        if stack.count > 1 { stack.removeLast() }
    }

    mutating func pushBinding(name: String, value: TemplateValue) {
        var frame: [String: TemplateValue] = [:]
        if case .object(let existing) = current {
            frame = existing
        }
        frame[name] = value
        // Also expose `.` as the bound item via a synthetic merge: keep parent keys + item.
        if case .object(let obj) = value {
            for (k, v) in obj { frame[k] = v }
        }
        stack.append(.object(frame))
    }

    func resolve(path: String) -> TemplateValue {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." {
            return current
        }
        let parts = trimmed.split(separator: ".").map(String.init)
        // Search from innermost frame outward.
        for frame in stack.reversed() {
            if let value = resolve(parts: parts, in: frame) {
                return value
            }
        }
        return .null
    }

    private func resolve(parts: [String], in value: TemplateValue) -> TemplateValue? {
        var current = value
        for part in parts {
            if part == "." { continue }
            if let idx = Int(part), case .array(let arr) = current {
                guard arr.indices.contains(idx) else { return .null }
                current = arr[idx]
                continue
            }
            guard case .object(let dict) = current, let next = dict[part] else {
                return nil
            }
            current = next
        }
        return current
    }
}
