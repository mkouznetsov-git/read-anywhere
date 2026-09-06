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

  test('duplicate and reordered chunks never duplicate bytes or create holes', () async {
    final expected = List<int>.generate(8, (index) => index);
    final prepared = await manager.prepare(
      PendingFileTransfer(
        transferId: 'transfer-ordering',
        bookId: 'book-ordering',
        fileName: 'ordered.bin',
        format: 'bin',
        expectedSha256: sha256.convert(expected).toString(),
        expectedBytes: expected.length,
        chunkSize: 4,
      ),
    );

    final futureChunk = await manager.commitChunk(
      partialFile: prepared.partialFile,
      expectedChunkIndex: 0,
      receivedChunkIndex: 1,
      chunkSize: 4,
      expectedBytes: expected.length,
      data: expected.sublist(4),
    );
    expect(futureChunk.disposition, IncomingChunkDisposition.waitingForMissingChunk);
    expect(await prepared.partialFile.length(), 0);

    final first = await manager.commitChunk(
      partialFile: prepared.partialFile,
      expectedChunkIndex: 0,
      receivedChunkIndex: 0,
      chunkSize: 4,
      expectedBytes: expected.length,
      data: expected.sublist(0, 4),
    );
    expect(first.disposition, IncomingChunkDisposition.appended);

    final duplicate = await manager.commitChunk(
      partialFile: prepared.partialFile,
      expectedChunkIndex: first.nextChunkIndex,
      receivedChunkIndex: 0,
      chunkSize: 4,
      expectedBytes: expected.length,
      data: expected.sublist(0, 4),
    );
    expect(duplicate.disposition, IncomingChunkDisposition.duplicate);
    expect(await prepared.partialFile.readAsBytes(), expected.sublist(0, 4));

    final second = await manager.commitChunk(
      partialFile: prepared.partialFile,
      expectedChunkIndex: first.nextChunkIndex,
      receivedChunkIndex: 1,
      chunkSize: 4,
      expectedBytes: expected.length,
      data: expected.sublist(4),
    );
    expect(second.disposition, IncomingChunkDisposition.appended);
    expect(await prepared.partialFile.readAsBytes(), expected);
    expect(await manager.verifySha256(prepared.partialFile, sha256.convert(expected).toString()), isTrue);
  });
}
