# ReadArc embedded reader engines

Sprint 33 starts the embedded-engine architecture. The app must not require
`brew install`, `apt install`, external command-line converters, or server-side
conversion to read user books.

Runtime rule:

```text
ReadArc Flutter UI
  -> Format Engine API
  -> embedded native/pure engines
  -> processed artifact cache
  -> safe reader widgets
```

Selected engines:

- DJVU: `djvu-rs`, MIT, pure Rust implementation from the public DjVu v3 specification.
- PDF: PDFium-backed engine direction; current Flutter package remains only until the native bridge is linked.
- CHM: CHMLib-compatible embedded library direction, LGPL-2.1-or-later.

No GPL DjVuLibre source is vendored in this tree.
