# ReadArc DJVU engine

ReadArc's DJVU support must be embedded in the app. The user must not install:

```text
brew install djvulibre
apt install djvulibre-bin
choco install ...
```

Sprint 34 adds the native C ABI and Dart FFI bridge:

```c
readarc_djvu_open
readarc_djvu_close
readarc_djvu_page_count
readarc_djvu_page_info
readarc_djvu_render_page_rgba
```

The Flutter reader asks this engine for a page rendered to RGBA, encodes it to PNG in Dart, stores it in the processed artifact cache, and displays the page in the same post-page style as PDF.

Packaging scripts try to bundle:

```text
Android: libreadarc_djvu_engine.so
macOS:   libreadarc_djvu_engine.dylib
```

If the engine is absent, ReadArc shows an in-reader diagnostic instead of falling back to external tools or closing the app.
