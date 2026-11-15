# SwiftDocxTemplate

Swift library for rendering Microsoft Word `.docx` templates with docxtpl / docxtemplater / Carbone-style tags.

**Requirements:** Swift 5.9+, iOS 16+ / macOS 13+

**License:** MIT ([LICENSE](LICENSE))

## Installation

Add this repository as a Swift Package Manager dependency. The package exposes one library product: **`SwiftDocxTemplate`**.

Repository URL: `https://github.com/mjanker4247/SwiftDocxTemplate.git`

### Xcode

1. **File → Add Package Dependencies…**
2. Paste `https://github.com/mjanker4247/SwiftDocxTemplate.git`
3. Choose **Up to Next Major Version** from `1.0.0` (or another released tag)
4. Add the **`SwiftDocxTemplate`** library product to your app/framework target

### `Package.swift`

```swift
dependencies: [
    .package(url: "https://github.com/mjanker4247/SwiftDocxTemplate.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftDocxTemplate", package: "SwiftDocxTemplate"),
        ]
    ),
]
```

Then:

```swift
import SwiftDocxTemplate
```

### Versioning

Use semantic version tags on `main` (annotated tags such as `1.0.0`). Consumers should pin with `from: "x.y.z"` (or Xcode’s “Up to Next Major”). Until a `1.0.0` tag exists on GitHub, Xcode/`from:` resolution will not find a release — create and push that tag after this package config lands on `main`.

## Quick start

For a full runnable sample (template + every working tag), see [`Examples/Quickstart`](Examples/Quickstart) and run:

```bash
swift run QuickstartExample
```

Minimal API usage:

```swift
import SwiftDocxTemplate

struct Invoice: Encodable {
    var customer: String
    var total: Double
}

let template = try DocxTemplate(templateURL: url)
let docx = try template.render(with: Invoice(customer: "Acme", total: 1200))
try docx.write(to: outputURL)
```

You can also pass an explicit context:

```swift
let docx = try template.render(context: [
    "customer": .string("Acme"),
    "total": .double(1200),
])
```

## Public API

### `DocxTemplate`

Entry point for loading and rendering a DOCX.

| API | Purpose |
| --- | --- |
| `init(templateURL:)` / `init(data:)` | Open a template from disk or memory |
| `render(with:)` | Encode an `Encodable` model and render |
| `render(context:)` | Render with `[String: TemplateValue]` |
| `getUndeclaredVariables()` | List variable names referenced by the template |
| `replaceMedia(placeholderFilename:with:)` | Swap a placeholder media file inside the archive |

### `TemplateValue`

Typed context values used by the renderer:

- Scalars: `.null`, `.bool`, `.int`, `.double`, `.string`, `.date`
- Nested: `.array`, `.object`
- Rich content: `.image(InlineImage)`, `.richText([RichTextRun])`

`Encodable` models are converted via `TemplateValueEncoder`. Literal syntax (`"name": .string("…")`, arrays, dictionaries) is also supported.

### Pipeline overview

Rendering walks WordprocessingML parts (`word/document.xml` plus headers/footers):

1. **Run normalizer** — merges split text runs so tags that Word broke across runs can be parsed
2. **Lexer / parser** — recognizes `{{ … }}` expressions and block tags (`{#…}`, `{/…}`, conditionals, loops)
3. **Expression / block evaluators** — resolve paths against the scoped context and expand or drop blocks
4. **Media injector** — embeds inline images and updates relationships when needed
5. **Archive serialize** — writes the ZIP/DOCX bytes back out

Errors surface as `DocxTemplateError` (invalid archive, missing `document.xml`, mismatched blocks, undeclared variables, media issues, and so on).

## Dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — DOCX ZIP I/O
- [AEXML](https://github.com/tadija/AEXML) — WordprocessingML parsing

## License

See [LICENSE](LICENSE).
