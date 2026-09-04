import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/format_engines/djvu_embedded_probe.dart';

void main() {
  test('detects single page DJVU container without external tools', () {
    final bytes = Uint8List.fromList([...'AT&T'.codeUnits, ...'FORM'.codeUnits, 0, 0, 0, 4, ...'DJVU'.codeUnits]);
    final result = DjvuEmbeddedProbe.inspect(bytes);
    expect(result.isDjvu, isTrue);
    expect(result.pageCount, 1);
    expect(result.kind, 'DJVU');
  });

  test('detects bundled DJVM page forms', () {
    final bytes = Uint8List.fromList([
      ...'AT&T'.codeUnits,
      ...'FORM'.codeUnits,
      0,
      0,
      0,
      32,
      ...'DJVM'.codeUnits,
      ...'FORM'.codeUnits,
      0,
      0,
      0,
      4,
      ...'DJVU'.codeUnits,
      ...'FORM'.codeUnits,
      0,
      0,
      0,
      4,
      ...'DJVI'.codeUnits,
    ]);
    final result = DjvuEmbeddedProbe.inspect(bytes);
    expect(result.isDjvu, isTrue);
    expect(result.pageCount, 2);
    expect(result.kind, 'DJVM');
  });

  test('rejects non DJVU bytes', () {
    final result = DjvuEmbeddedProbe.inspect(Uint8List.fromList('not a book'.codeUnits));
    expect(result.isDjvu, isFalse);
    expect(result.pageCount, 0);
  });
}
