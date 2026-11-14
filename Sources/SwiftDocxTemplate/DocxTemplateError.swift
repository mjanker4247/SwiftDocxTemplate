import Foundation

/// Errors thrown by `DocxTemplate` and the rendering pipeline.
public enum DocxTemplateError: Error, Equatable, Sendable {
    case invalidArchive
    case missingDocumentXML
    case malformedXML(String)
    case undeclaredVariable(String)
    case invalidExpression(String)
    case mismatchedBlock(String)
    case mediaNotFound(String)
    case unsupportedFilter(String)
    case encodingFailed(String)
    case ioError(String)

    public var localizedDescription: String {
        switch self {
        case .invalidArchive:
            return "The provided data is not a valid DOCX (ZIP) archive."
        case .missingDocumentXML:
            return "The DOCX archive does not contain word/document.xml."
        case .malformedXML(let detail):
            return "Malformed WordprocessingML: \(detail)"
        case .undeclaredVariable(let name):
            return "Undeclared template variable: \(name)"
        case .invalidExpression(let expr):
            return "Invalid template expression: \(expr)"
        case .mismatchedBlock(let detail):
            return "Mismatched template block: \(detail)"
        case .mediaNotFound(let name):
            return "Media placeholder not found: \(name)"
        case .unsupportedFilter(let name):
            return "Unsupported filter: \(name)"
        case .encodingFailed(let detail):
            return "Failed to encode model: \(detail)"
        case .ioError(let detail):
            return "I/O error: \(detail)"
        }
    }
}
