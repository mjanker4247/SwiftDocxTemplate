import Foundation
import SwiftDocxTemplate

// MARK: - Report model
//
// Property names become top-level (or nested) keys in the render context.
// Template tags reference those keys with Mustache-style paths, for example:
//   {{ reportTitle }}
//   {{ company.address.city }}
//   {%tr for item in items %} … {{ item.sku }} … {% endtr %}
//
// Prefer a typed Encodable model for scalars, nested objects, arrays, and dates.
// Values that cannot be expressed as JSON-like data (inline images, rich text)
// are attached after encoding — see the context-building section in `main()`.

/// Sample report context that maps 1:1 onto tags in `ReportTemplate.docx`.
///
/// Nested structs encode as nested objects; arrays drive `{%p for %}`, `{%tr for %}`,
/// and `{#…}` loops. Booleans feed `{%p if %}` and inverted `{^…}` sections.
struct QuickstartReport: Encodable {
    /// Nested address object → `{{ company.address.city }}`, `{{ company.address.country }}`.
    struct Address: Encodable {
        var city: String
        var country: String
    }

    /// Nested company object → `{{ company.name }}` and address paths above.
    struct Company: Encodable {
        var name: String
        var address: Address
    }

    /// Nested customer object → `{{ customer.name }}`, `{{ customer.title }}`.
    struct Customer: Encodable {
        var name: String
        var title: String
    }

    /// One table-row payload for `{%tr for item in items %}…{% endtr %}`.
    /// Inside the loop, use `{{ item.sku }}`, `{{ item.qty }}`, `{{ item.price }}`.
    struct LineItem: Encodable {
        var sku: String
        var qty: Int
        var price: Double
    }

    // Scalars & filters (see README for which filters the template applies)
    var reportTitle: String
    var reportDate: Date
    var status: String
    var productName: String
    /// Empty string demos the `default` filter when the template supplies a fallback.
    var nickname: String
    var total: Double
    /// Newlines are preserved in Word via the `linebreaks` filter.
    var multiLineNotes: String

    var company: Company
    var customer: Customer

    /// Controls `{%p if showPremium %}…{% endp %}` (paragraph kept when true).
    var showPremium: Bool
    /// Controls the inverted section `{^hasNotes}…{/hasNotes}` (shown when false/empty).
    var hasNotes: Bool

    /// Paragraph loop: `{%p for note in notes %}…{% endp %}`.
    var notes: [String]
    /// Docxtemplater-style loop: `{#tags}…{/tags}`.
    var tags: [String]
    /// Table-row loop over `LineItem` rows.
    var items: [LineItem]

    /// Demonstrates Carbone `:drop(p)` — the host paragraph is removed at render time.
    var discardedNote: String
    /// Demonstrates Carbone `drop(tr)` — the host table row is removed at render time.
    var hiddenRow: String
}

// MARK: - Executable entry point

@main
enum QuickstartExample {
    static func main() throws {
        // ── 1. Locate packaged resources ───────────────────────────────────
        // SPM copies `ReportTemplate.docx` and `logo.png` into the example bundle.
        // `resourceURL` falls back to paths next to this source file for ad-hoc runs.
        let templateURL = try resourceURL(named: "ReportTemplate", ext: "docx")
        let logoURL = try resourceURL(named: "logo", ext: "png")

        // ── 2. Load the template ───────────────────────────────────────────
        // `DocxTemplate` opens the DOCX archive once; call `render` as often as needed.
        let template = try DocxTemplate(templateURL: templateURL)

        // ── 3. Inspect undeclared / referenced variables ───────────────────
        // Scans template parts for `{{ … }}` / block tag names before you render.
        // Useful while authoring: compare this list to the keys you will supply.
        let undeclared = try template.getUndeclaredVariables()
        print("Undeclared / referenced variables (\(undeclared.count)):")
        for name in undeclared.sorted() {
            print("  - \(name)")
        }
        print()

        // ── 4. Populate the Encodable model ────────────────────────────────
        // Values below are chosen to exercise filters, loops, and conditionals
        // in `ReportTemplate.docx`. Adjust them freely when experimenting.
        let model = QuickstartReport(
            reportTitle: "Q4 Operations Report",
            reportDate: Date(timeIntervalSince1970: 1_731_456_000), // 2024-11-13 UTC
            status: "draft",
            productName: "swiftDocx",
            nickname: "",
            total: 1284.5,
            multiLineNotes: "Line one\nLine two\nLine three",
            company: .init(
                name: "Acme Robotics",
                address: .init(city: "Berlin", country: "Germany")
            ),
            customer: .init(name: "Ada Lovelace", title: "principal engineer"),
            showPremium: true,
            hasNotes: false,
            notes: [
                "Ship sample DOCX template with the package.",
                "Demonstrate filters, loops, and conditionals.",
                "Write rendered output next to the working directory.",
            ],
            tags: ["docx", "templates", "swift"],
            items: [
                .init(sku: "A-100", qty: 3, price: 19.99),
                .init(sku: "B-200", qty: 1, price: 249.0),
                .init(sku: "C-300", qty: 12, price: 4.5),
            ],
            discardedNote: "This entire paragraph is removed by :drop(p).",
            hiddenRow: "This entire table row is removed by drop(tr)."
        )

        // ── 5. Build the render context ────────────────────────────────────
        // `TemplateValueEncoder` turns the Encodable model into `[String: TemplateValue]`.
        // Merge non-Encodable cases afterward:
        //   - `.image(InlineImage…)`  → `{{ logo }}`
        //   - `.richText([RichTextRun…])` → `{{ summary }}`
        // Alternatively, call `template.render(with: model)` when you only need
        // Encodable data and no image/rich-text keys.
        var context = try TemplateValueEncoder().encode(model)
        context["logo"] = .image(InlineImage(url: logoURL, widthMm: 20, heightMm: 20))
        context["summary"] = .richText([
            RichTextRun(text: "Summary: ", bold: true),
            RichTextRun(text: "all working tags ", italic: true),
            RichTextRun(text: "are exercised", underline: true),
            RichTextRun(text: " in this quickstart."),
        ])

        // ── 6. Render ──────────────────────────────────────────────────────
        // Substitutes variables, evaluates loops/conditionals/filters, and
        // injects media. Returns the finished DOCX as `Data` (does not write a file).
        let rendered = try template.render(context: context)

        // ── 7. Resolve output path and write ───────────────────────────────
        // Path is relative to the process working directory (repo root when you
        // run `swift run QuickstartExample` from there). `Output/` is gitignored.
        let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Examples/Quickstart/Output")
            .appendingPathComponent("report.docx")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try rendered.write(to: outputURL, options: .atomic)

        print("Rendered \(rendered.count) bytes")
        print("Output: \(outputURL.path)")
    }

    /// Resolves a bundled resource, with a filesystem fallback beside this source file.
    ///
    /// Prefer `Bundle.module` when the example is built via SwiftPM (resources are
    /// declared in `Package.swift`). The `#filePath` fallback helps when opening
    /// the DOCX/PNG directly during local exploration.
    private static func resourceURL(named name: String, ext: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        let nearby = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).\(ext)")
        guard FileManager.default.fileExists(atPath: nearby.path) else {
            throw DocxTemplateError.ioError("Missing resource \(name).\(ext)")
        }
        return nearby
    }
}
