# ReadArc DJVU engine

Decision: use an embedded MIT-licensed Rust decoder (`djvu-rs`) and expose it to
Flutter through a small C ABI / FFI layer.

Sprint 33 removes the external `ddjvu`, `djvused`, and `djvutxt` runtime path.
The remaining work is to implement and link these ABI functions per platform:

```c
readarc_djvu_open
readarc_djvu_close
readarc_djvu_page_count
readarc_djvu_render_page_rgba
readarc_djvu_extract_page_text
readarc_djvu_read_toc_json
```

The processed artifact cache remains the reader-facing contract:

```text
processed_artifacts/<bookId>/artifact.json
processed_artifacts/<bookId>/pages/page_00001.rgba|png|webp
processed_artifacts/<bookId>/text/page_00001.txt
processed_artifacts/<bookId>/toc.json
```
