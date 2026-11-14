import Foundation
import SwiftDocxTemplate

/// Sample report context mixing Encodable scalars with rich TemplateValue entries.
struct QuickstartReport: Encodable {
    struct Address: Encodable {
        var city: String
        var country: String
    }

    struct Company: Encodable {
        var name: String
        var address: Address
    }

    struct Customer: Encodable {
        var name: String
        var title: String
    }

    struct LineItem: Encodable {
        var sku: String
        var qty: Int
        var price: Double
    }

    var reportTitle: String
    var reportDate: Date
    var status: String
    var productName: String
    var nickname: String
    var total: Double
    var multiLineNotes: String
    var company: Company
    var customer: Customer
    var showPremium: Bool
    var hasNotes: Bool
    var notes: [String]
    var tags: [String]
    var items: [LineItem]
    var discardedNote: String
    var hiddenRow: String
}

@main
enum QuickstartExample {
    static func main() throws {
        let templateURL = try resourceURL(named: "ReportTemplate", ext: "docx")
        let logoURL = try resourceURL(named: "logo", ext: "png")

        let template = try DocxTemplate(templateURL: templateURL)

        let undeclared = try template.getUndeclaredVariables()
        print("Undeclared / referenced variables (\(undeclared.count)):")
        for name in undeclared.sorted() {
            print("  - \(name)")
        }
        print()

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

        // Encode the Encodable model, then attach values that need TemplateValue cases
        // (InlineImage / RichTextRun) which are not JSON-like scalars.
        var context = try TemplateValueEncoder().encode(model)
        context["logo"] = .image(InlineImage(url: logoURL, widthMm: 20, heightMm: 20))
        context["summary"] = .richText([
            RichTextRun(text: "Summary: ", bold: true),
            RichTextRun(text: "all working tags ", italic: true),
            RichTextRun(text: "are exercised", underline: true),
            RichTextRun(text: " in this quickstart."),
        ])

        let rendered = try template.render(context: context)

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
