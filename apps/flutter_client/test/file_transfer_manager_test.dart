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

  test('durable append accepts a chunk once and ignores duplicates or reordering', () async {
    final bytes = List<int>.generate(10, (index) => index);
    final transfer = _transfer('book-chunks', bytes, chunkSize: 4);
    final prepared = await manager.prepare(transfer);

    final premature = await manager.appendChunk(
      transfer: transfer,
      partialFile: prepared.partialFile,
      expectedChunkIndex: 0,
      chunkIndex: 1,
      offset: 4,
      totalChunks: 3,
      totalBytes: bytes.length,
      sha256: transfer.expectedSha256,
      data: bytes.sublist(4, 8),
    );
    expect(premature.status, FileChunkAppendStatus.premature);
    expect(await prepared.partialFile.length(), 0);

    final appended = await manager.appendChunk(
      transfer: transfer,
      partialFile: prepared.partialFile,
      expectedChunkIndex: 0,
      chunkIndex: 0,
      offset: 0,
      totalChunks: 3,
      totalBytes: bytes.length,
      sha256: transfer.expectedSha256,
      data: bytes.sublist(0, 4),
    );
    expect(appended.status, FileChunkAppendStatus.appended);
    expect(appended.receivedBytes, 4);

    final duplicate = await manager.appendChunk(
      transfer: transfer,
      partialFile: prepared.partialFile,
      expectedChunkIndex: 1,
      chunkIndex: 0,
      offset: 0,
      totalChunks: 3,
      totalBytes: bytes.length,
      sha256: transfer.expectedSha256,
      data: bytes.sublist(0, 4),
    );
    expect(duplicate.status, FileChunkAppendStatus.duplicate);
    expect(await prepared.partialFile.readAsBytes(), bytes.sublist(0, 4));
  });

  test('incompatible offset, geometry, size or SHA never mutates the partial', () async {
    final bytes = List<int>.generate(8, (index) => index);
    final transfer = _transfer('book-invalid', bytes, chunkSize: 4);
    final prepared = await manager.prepare(transfer);

    for (final invalid in [
      (offset: 1, totalChunks: 2, totalBytes: 8, sha256: transfer.expectedSha256, data: bytes.sublist(0, 4)),
      (offset: 0, totalChunks: 3, totalBytes: 8, sha256: transfer.expectedSha256, data: bytes.sublist(0, 4)),
      (offset: 0, totalChunks: 2, totalBytes: 9, sha256: transfer.expectedSha256, data: bytes.sublist(0, 4)),
      (offset: 0, totalChunks: 2, totalBytes: 8, sha256: List.filled(64, '0').join(), data: bytes.sublist(0, 4)),
      (offset: 0, totalChunks: 2, totalBytes: 8, sha256: transfer.expectedSha256, data: bytes.sublist(0, 3)),
    ]) {
      final result = await manager.appendChunk(
        transfer: transfer,
        partialFile: prepared.partialFile,
        expectedChunkIndex: 0,
        chunkIndex: 0,
        offset: invalid.offset,
        totalChunks: invalid.totalChunks,
        totalBytes: invalid.totalBytes,
        sha256: invalid.sha256,
        data: invalid.data,
      );
      expect(result.status, FileChunkAppendStatus.invalid);
      expect(await prepared.partialFile.length(), 0);
    }
  });

  test('restart recovers a verified temp or previous journal generation', () async {
    final bytes = List<int>.generate(8, (index) => index);
    final transfer = _transfer('book-journal', bytes, chunkSize: 4);
    await manager.prepare(transfer);
    final incoming = Directory('${directory.path}/incoming');
    final journal = File('${incoming.path}/book-journal.transfer.json');
    final previous = File('${journal.path}.prev');
    await journal.rename(previous.path);

    expect((await manager.loadPending()).single.transferId, transfer.transferId);
    expect(await journal.exists(), isTrue);

    await journal.rename(previous.path);
    await File(journal.path).writeAsString('{corrupt', flush: true);
    expect((await manager.loadPending()).single.bookId, transfer.bookId);
  });

  test('unsafe book ids cannot escape the incoming directory', () async {
    final transfer = PendingFileTransfer(
      transferId: 'transfer-unsafe',
      bookId: '../outside',
      fileName: 'book.bin',
      format: 'bin',
      expectedSha256: List.filled(64, '0').join(),
      expectedBytes: 0,
      chunkSize: 4,
    );
    await expectLater(manager.prepare(transfer), throwsFormatException);
  });
}

PendingFileTransfer _transfer(String bookId, List<int> bytes, {required int chunkSize}) => PendingFileTransfer(
  transferId: 'transfer-$bookId',
  bookId: bookId,
  fileName: 'book.bin',
  format: 'bin',
  expectedSha256: sha256.convert(bytes).toString(),
  expectedBytes: bytes.length,
  chunkSize: chunkSize,
);
