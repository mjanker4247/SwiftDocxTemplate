import Foundation

/// An inline image that can be injected into a rendered DOCX.
public struct InlineImage: Equatable, Sendable {
    public var url: URL
    public var widthMm: Double
    public var heightMm: Double

    public init(url: URL, widthMm: Double, heightMm: Double) {
        self.url = url
        self.widthMm = widthMm
        self.heightMm = heightMm
    }
}

/// A single run of rich text with optional formatting flags.
public struct RichTextRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// Typed values that can appear in a DOCX template context.
public enum TemplateValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case array([TemplateValue])
    case object([String: TemplateValue])
    case image(InlineImage)
    case richText([RichTextRun])

    /// Returns a string suitable for text substitution (non-media values).
    public var stringValue: String? {
        switch self {
        case .null:
            return nil
        case .bool(let v):
            return v ? "true" : "false"
        case .int(let v):
            return String(v)
        case .double(let v):
            return String(v)
        case .string(let v):
            return v
        case .date(let v):
            return ISO8601DateFormatter().string(from: v)
        case .array, .object, .image, .richText:
            return nil
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null:
            return false
        case .bool(let v):
            return v
        case .int(let v):
            return v != 0
        case .double(let v):
            return v != 0
        case .string(let v):
            return !v.isEmpty
        case .array(let v):
            return !v.isEmpty
        case .object(let v):
            return !v.isEmpty
        case .date, .image, .richText:
            return true
        }
    }

    public subscript(key: String) -> TemplateValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    public subscript(index: Int) -> TemplateValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

extension TemplateValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension TemplateValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension TemplateValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension TemplateValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension TemplateValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension TemplateValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TemplateValue...) {
        self = .array(elements)
    }
}

extension TemplateValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TemplateValue)...) {
        var dict: [String: TemplateValue] = [:]
        for (key, value) in elements {
            dict[key] = value
        }
        self = .object(dict)
    }
}
