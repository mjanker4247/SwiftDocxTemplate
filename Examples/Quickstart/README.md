# Quickstart example

Minimal runnable sample for [SwiftDocxTemplate](https://github.com/mjanker4247/SwiftDocxTemplate): load a real `.docx` template, build a rich context, call `DocxTemplate.render`, and write an output document.

## Run

From the repository root:

```bash
swift run QuickstartExample
```

Output is written to:

```text
Examples/Quickstart/Output/report.docx
```

(`Output/` is gitignored.)

## What’s in this folder

| File | Role |
| --- | --- |
| `ReportTemplate.docx` | Word template with tags |
| `logo.png` | Tiny PNG used by `TemplateValue.image` / `InlineImage` |
| `Quickstart.swift` | Executable entry point (`QuickstartExample`) |
| `README.md` | This file |

## Tags & features demonstrated

| Feature | Template usage |
| --- | --- |
| Variables / nested paths | `{{ customer.name }}`, `{{ company.address.city }}` |
| Filters | `upper`, `lower`, `capitalize`, `default`, `number`, `date`, `linebreaks` |
| Paragraph conditional | `{%p if showPremium %}…{% endp %}` |
| Inverted section | `{^hasNotes}…{/hasNotes}` |
| Paragraph loop | `{%p for note in notes %}…{% endp %}` |
| Docxtemplater loop | `{#tags}…{/tags}` |
| Table row loop | `{%tr for item in items %}…{% endtr %}` |
| Carbone drop filters | `{{ … \| :drop(p) }}`, `{{ … \| drop(tr) }}` |
| Inline image | `{{ logo }}` → `TemplateValue.image` |
| Rich text | `{{ summary }}` → `TemplateValue.richText` |
| Header / footer | Header & footer paragraphs with variables/filters |
| `getUndeclaredVariables` | Printed to stdout before render |
| Encodable + dictionary | Model encoded via `TemplateValueEncoder`, then image/rich text merged into the context |

## Intentional omissions

These are **not** shown because they are limited or not end-to-end reliable in the current library:

- **Nested DOM loops** — outer `{%p for %}` / `{%tr for %}` / `{#…}` expansion strips residual block tags inside cloned hosts, so nested loop tags inside a cloned paragraph/row do not expand correctly.
- **`{% else %}` branch content in Word** — the lexer/parser understands `else`, but DOM evaluation keeps or removes the whole host paragraph/row. Use a separate `{%p if %}` paragraph and/or `{^…}` instead of if/else pairs in one block.
- **`{#bool}` as a truthy conditional** — `{#name}` is always treated as a **loop over an array**. Non-arrays remove the host. Prefer `{%p if %}` / `{^…}` for booleans.
- **`{%tc for %}` / `{%r for %}`** — scopes exist in the lexer; this sample sticks to the exercised `{%tr %}` / `{%p %}` / `{#…}` paths covered by tests.
- **`replaceMedia(placeholderFilename:with:)`** — supported API (swap a media file already embedded in the template). This sample injects a new image via `InlineImage` instead.

## Template tips

- Keep `{%tr for … %}` and `{% endtr %}` in the **same** table cell. Sibling cells may still use `{{ item.… }}` and are rewritten when the row is cloned.
- Avoid putting real tag syntax in headings/labels (for example a literal `{#…}` in a section title); the engine will try to parse it.
