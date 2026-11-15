import Foundation
import ZIPFoundation

/// Thin wrapper around ZIPFoundation for reading and writing DOCX archives.
public struct DocxArchive: Sendable {
    public private(set) var entries: [String: Data]

    public init(data: Data) throws {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocxTemplateError.invalidArchive
        }
        var map: [String: Data] = [:]
        for entry in archive {
            var extracted = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    extracted.append(chunk)
                }
            } catch {
                throw DocxTemplateError.ioError("Failed to extract \(entry.path): \(error)")
            }
            map[entry.path] = extracted
        }
        self.entries = map
    }

    public init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocxTemplateError.ioError("Failed to read \(url.path): \(error)")
        }
        try self.init(data: data)
    }

    public init(entries: [String: Data]) {
        self.entries = entries
    }

    public func data(at path: String) -> Data? {
        entries[path]
    }

    public mutating func setData(_ data: Data, at path: String) {
        entries[path] = data
    }

    public mutating func removeData(at path: String) {
        entries.removeValue(forKey: path)
    }

    public var documentXML: Data? {
        data(at: "word/document.xml")
    }

    public mutating func setDocumentXML(_ data: Data) {
        setData(data, at: "word/document.xml")
    }

    /// Returns paths for `word/header*.xml` and `word/footer*.xml`.
    public var headerFooterPaths: [String] {
        entries.keys
            .filter { path in
                let name = (path as NSString).lastPathComponent
                return path.hasPrefix("word/")
                    && (name.hasPrefix("header") || name.hasPrefix("footer"))
                    && name.hasSuffix(".xml")
            }
            .sorted()
    }

    /// Serializes the archive back into DOCX (ZIP) bytes (fully in memory).
    public func serialize() throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(accessMode: .create)
        } catch {
            throw DocxTemplateError.ioError("Failed to create in-memory ZIP archive: \(error)")
        }

        for path in entries.keys.sorted() {
            guard let payload = entries[path] else { continue }
            do {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(payload.count),
                    provider: { position, size in
                        let count = payload.count
                        guard position >= 0, size >= 0 else { return Data() }
                        let start = Int(position)
                        guard start < count else { return Data() }
                        let remaining = count - start
                        let length = min(size, remaining)
                        return payload.subdata(in: start..<(start + length))
                    }
                )
            } catch {
                throw DocxTemplateError.ioError("Failed to write \(path): \(error)")
            }
        }

        guard let data = archive.data else {
            throw DocxTemplateError.ioError("Failed to materialize in-memory archive")
        }
        return data
    }
}
