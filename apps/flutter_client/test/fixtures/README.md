# ReadArc regression fixtures

This directory is reserved for deterministic document fixtures used by automated reader tests.

Planned canonical fixtures:

- `docx_contract.docx` — page size/margins, headings, multilevel numbering, tabs, blank paragraphs, page breaks, headers/footers, merged table cells, bold/italic runs.
- `epub_navigation.epub` — cover, images, NCX/nav TOC, internal `path#fragment` links, notes, paragraphs and nested containers.
- `fb2_smoke.fb2` — formatted paragraphs, images and sections.
- `pdf_smoke.pdf` — text-bearing PDF for open/copy/progress smoke checks.
- `djvu_smoke.djvu` — deterministic single/multipage sample for the embedded engine.

Rules:

1. Fixtures must be small and redistributable in the repository.
2. Tests must assert semantic structure first; pixel/golden checks are a second layer.
3. A fixture that reproduces a production regression must never be silently replaced with an easier file.
4. Large/private user books are not committed. A reduced synthetic fixture should be produced from the failing structure.
