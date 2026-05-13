# ReadArc embedded reader engines

Runtime rule:

```text
ReadArc Flutter UI
  -> Format Engine API
  -> embedded native/pure engines
  -> processed artifact cache
  -> safe reader widgets
```

ReadArc must not require users to install Homebrew, apt packages, command-line converters or server-side conversion services to read their books.

Current engine decisions:

- DJVU: `djvu-rs` permissive/MIT crate path, wrapped by `readarc_djvu_engine` C ABI and Dart FFI.
- PDF: current Flutter `pdfx` path is normalized to a page-by-page reader; long-term direction is a bundled PDFium-backed engine.
- CHM: future embedded CHMLib-compatible reader.

No DjVuLibre source and no GPL DJVU runtime tools are vendored in this tree.
