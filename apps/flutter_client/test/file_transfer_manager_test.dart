import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/sync/file_transfer_manager.dart';

void main() {
  late Directory directory;
  late FileTransferManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('readarc-transfer-');
    manager = FileTransferManager(appDirectory: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('restart reloads journal and resumes at a safe chunk boundary', () async {
    final bytes = List<int>.generate(12, (index) => index);
    final transfer = PendingFileTransfer(
      transferId: 'transfer-1',
      bookId: 'book-1',
      fileName: 'book.txt',
      format: 'txt',
      expectedSha256: sha256.convert(bytes).toString(),
      expectedBytes: bytes.length,
      chunkSize: 4,
    );
    final first = await manager.prepare(transfer);
    await first.partialFile.writeAsBytes(bytes.take(10).toList(), flush: true);

    final restarted = FileTransferManager(appDirectory: () async => directory);
    final pending = await restarted.loadPending();
    final prepared = await restarted.prepare(pending.single);

    expect(prepared.resumeBytes, 8);
    expect(prepared.nextChunkIndex, 2);
    expect(await prepared.partialFile.length(), 8);
  });

  test('completion accepts the exact SHA-256 and rejects corruption', () async {
    final expected = List<int>.generate(64, (index) => index);
    final hash = sha256.convert(expected).toString();
    final transfer = PendingFileTransfer(
      transferId: 'transfer-2',
      bookId: 'book-2',
      fileName: 'book.bin',
      format: 'bin',
      expectedSha256: hash,
      expectedBytes: expected.length,
      chunkSize: 16,
    );
    final prepared = await manager.prepare(transfer);
    await prepared.partialFile.writeAsBytes(expected, flush: true);
    expect(await manager.verifySha256(prepared.partialFile, hash), isTrue);

    await prepared.partialFile.writeAsBytes([0], mode: FileMode.append, flush: true);
    expect(await manager.verifySha256(prepared.partialFile, hash), isFalse);
  });
}
