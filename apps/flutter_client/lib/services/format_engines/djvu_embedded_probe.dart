import 'dart:convert';
import 'dart:typed_data';

/// Lightweight embedded DjVu container probe.
///
/// This is intentionally pure Dart and does not call ddjvu/djvused/djvutxt.
/// It is the first safe layer of the embedded DjVu engine path: identify the
/// container and estimate the page count without external tools. Page decoding
/// is handled by the native/Rust engine that lives behind the same engine API.
class DjvuEmbeddedProbe {
  const DjvuEmbeddedProbe._();

  static DjvuProbeResult inspect(Uint8List bytes) {
    if (bytes.length < 16) return const DjvuProbeResult(isDjvu: false, pageCount: 0, kind: 'unknown');
    final ascii = latin1.decode(bytes, allowInvalid: true);
    final hasDjvuMagic =
        ascii.startsWith('AT&TFORM') || ascii.contains('FORM') && (ascii.contains('DJVU') || ascii.contains('DJVM'));
    if (!hasDjvuMagic) return const DjvuProbeResult(isDjvu: false, pageCount: 0, kind: 'unknown');

    final isBundled = ascii.contains('DJVM');
    var pages = _countFormPages(bytes);
    if (pages <= 0) pages = _countDirectoryCandidates(ascii);
    if (pages <= 0 && ascii.contains('DJVU')) pages = 1;
    return DjvuProbeResult(isDjvu: true, pageCount: pages <= 0 ? 1 : pages, kind: isBundled ? 'DJVM' : 'DJVU');
  }

  static int _countFormPages(Uint8List bytes) {
    var count = 0;
    for (var i = 0; i + 12 <= bytes.length; i++) {
      if (bytes[i] == 0x46 && bytes[i + 1] == 0x4f && bytes[i + 2] == 0x52 && bytes[i + 3] == 0x4d) {
        final type = latin1.decode(bytes.sublist(i + 8, i + 12), allowInvalid: true);
        if (type == 'DJVU' || type == 'DJVI') count++;
      }
    }
    return count;
  }

  static int _countDirectoryCandidates(String ascii) {
    // Bundled DJVM files usually contain one directory entry per page. This is
    // not a full DIRM parser yet, but it is good enough to avoid external tools
    // for initial reader setup and diagnostics.
    final candidates = RegExp(r'\.djvu|\.djv|\.iw4', caseSensitive: false).allMatches(ascii).length;
    return candidates;
  }
}

class DjvuProbeResult {
  const DjvuProbeResult({required this.isDjvu, required this.pageCount, required this.kind});

  final bool isDjvu;
  final int pageCount;
  final String kind;
}
