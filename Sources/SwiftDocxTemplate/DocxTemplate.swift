import Foundation

/// Renders Word DOCX templates using docxtpl / docxtemplater / Carbone-style tags.
public struct DocxTemplate {
    private var archive: DocxArchive
    private var mediaReplacements: [String: URL] = [:]

    public init(templateURL: URL) throws {
        self.archive = try DocxArchive(url: templateURL)
        guard archive.documentXML != nil else {
            throw DocxTemplateError.missingDocumentXML
        }
    }

    public init(data: Data) throws {
        self.archive = try DocxArchive(data: data)
        guard archive.documentXML != nil else {
            throw DocxTemplateError.missingDocumentXML
        }
    }

    /// Renders the template using an `Encodable` model.
    public func render<T: Encodable>(with model: T) throws -> Data {
        let context = try TemplateValueEncoder().encode(model)
        return try render(context: context)
    }

    /// Renders the template using an explicit context dictionary.
    public func render(context: [String: TemplateValue]) throws -> Data {
        var working = archive

        for (placeholder, url) in mediaReplacements {
            try Self.applyMediaReplacement(placeholder: placeholder, imageURL: url, into: &working)
        }

        var pipeline = DocumentPipeline(
            context: ScopeContext(root: context),
            archive: working
        )

        var parts = ["word/document.xml"]
        parts.append(contentsOf: working.headerFooterPaths)

        for path in parts {
            guard let xml = working.data(at: path) else { continue }
            // Keep pipeline archive in sync for media injections into relationships.
            pipeline.archive = working
            let rendered = try pipeline.render(xml: xml)
            working = pipeline.archive
            working.setData(rendered, at: path)
        }

        return try working.serialize()
    }

    /// Returns variable names referenced by the template.
    public func getUndeclaredVariables() throws -> Set<String> {
        try UndeclaredVariableScanner.scan(archive: archive)
    }

    /// Registers a media file replacement for a placeholder image filename inside the template.
    public mutating func replaceMedia(placeholderFilename: String, with imageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DocxTemplateError.mediaNotFound(imageURL.lastPathComponent)
        }
        mediaReplacements[placeholderFilename] = imageURL
    }

    private static func applyMediaReplacement(
        placeholder: String,
        imageURL: URL,
        into archive: inout DocxArchive
    ) throws {
        let mediaPrefix = "word/media/"
        let candidates = archive.entries.keys.filter { path in
            path.hasPrefix(mediaPrefix)
                && ((path as NSString).lastPathComponent == placeholder
                    || path.hasSuffix("/\(placeholder)"))
        }
        guard let target = candidates.first else {
            throw DocxTemplateError.mediaNotFound(placeholder)
        }
        let data: Data
        do {
            data = try Data(contentsOf: imageURL)
        } catch {
            throw DocxTemplateError.ioError("Failed to read image at \(imageURL.path): \(error)")
        }
        archive.setData(data, at: target)
    }
}
