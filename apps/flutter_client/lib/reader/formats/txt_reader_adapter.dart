part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizeTxt(Uint8List bytes) {
  final text = _normalizeText(_decodeTextFile(bytes));
  final blocks = <ReaderBlockSnapshot>[];
  final starts = <int>[];
  var cursor = 0;
  for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
    final normalized = paragraph.trim();
    if (normalized.isEmpty) continue;
    starts.add(cursor);
    blocks.add(ReaderBlockSnapshot(type: ReaderBlockType.paragraph, text: normalized));
    cursor += normalized.length + 1;
  }
  if (blocks.isEmpty && text.isNotEmpty) {
    blocks.add(ReaderBlockSnapshot(type: ReaderBlockType.paragraph, text: text));
    starts.add(0);
    cursor = text.length;
  }
  return ReaderDocumentSnapshot(
    format: ReaderFormat.txt,
    blocks: blocks,
    anchors: const {},
    blockStartChars: starts,
    totalTextChars: cursor,
    pageCount: 0,
  );
}
