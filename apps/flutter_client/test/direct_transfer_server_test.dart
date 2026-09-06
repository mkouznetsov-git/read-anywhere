import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/services/sync/direct_transfer_server.dart';
import 'package:readarc/services/sync/file_transfer_manager.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('readarc-direct-transfer-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('Direct/LAN Range resumes after manager restart and verifies SHA-256', () async {
    const chunkSize = 64 * 1024;
    final bytes = List<int>.generate(chunkSize * 5 + 123, (index) => index % 251);
    final hash = sha256.convert(bytes).toString();
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes(bytes, flush: true);
    final server = DirectTransferServer(includeLoopback: true);
    final urls = await server.createShareUrls(book: _book(source, hash, bytes.length), file: source);
    final uri = Uri.parse(urls.firstWhere((url) => url.contains('127.0.0.1')));
    final transfer = PendingFileTransfer(
      transferId: 'direct-resume',
      bookId: 'book',
      fileName: 'source.bin',
      format: 'bin',
      expectedSha256: hash,
      expectedBytes: bytes.length,
      chunkSize: chunkSize,
    );

    try {
      final firstManager = FileTransferManager(appDirectory: () async => directory);
      final first = await firstManager.prepare(transfer);
      final firstResponse = await _read(uri, range: 'bytes=0-${chunkSize * 2 - 1}');
      expect(firstResponse.statusCode, HttpStatus.partialContent);
      await first.partialFile.writeAsBytes(firstResponse.body);
      expect(await first.partialFile.length(), chunkSize * 2);

      final restartedManager = FileTransferManager(appDirectory: () async => directory);
      final pending = (await restartedManager.loadPending()).single;
      final resumed = await restartedManager.prepare(pending);
      expect(resumed.resumeBytes, chunkSize * 2);
      final rest = await _read(uri, range: 'bytes=${resumed.resumeBytes}-');
      expect(rest.statusCode, HttpStatus.partialContent);
      expect(rest.contentRange, 'bytes ${chunkSize * 2}-${bytes.length - 1}/${bytes.length}');
      await resumed.partialFile.writeAsBytes(rest.body, mode: FileMode.append, flush: true);

      expect(await resumed.partialFile.readAsBytes(), bytes);
      expect(await restartedManager.verifySha256(resumed.partialFile, hash), isTrue);
    } finally {
      await server.dispose();
    }
  });

  test('revocation closes an active Direct/LAN response and invalidates its token', () async {
    final bytes = List<int>.generate(1024 * 1024, (index) => index % 239);
    final hash = sha256.convert(bytes).toString();
    final source = File('${directory.path}/revoked.bin');
    await source.writeAsBytes(bytes, flush: true);
    final server = DirectTransferServer(
      includeLoopback: true,
      streamChunkSize: 16 * 1024,
      streamChunkDelay: const Duration(milliseconds: 8),
    );
    final urls = await server.createShareUrls(book: _book(source, hash, bytes.length), file: source);
    final uri = Uri.parse(urls.firstWhere((url) => url.contains('127.0.0.1')));
    final client = HttpClient();

    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      var received = 0;
      try {
        await for (final part in response) {
          received += part.length;
          if (received > 0) server.revokeAllShares();
        }
      } on HttpException {
        // Expected: content-length cannot be fulfilled after active revocation.
      }
      expect(received, greaterThan(0));
      expect(received, lessThan(bytes.length));

      final rejected = await _read(uri);
      expect(rejected.statusCode, HttpStatus.notFound);
    } finally {
      client.close(force: true);
      await server.dispose();
    }
  });
}

BookRecord _book(File source, String hash, int size) => BookRecord(
  id: 'book',
  title: 'Book',
  fileName: source.uri.pathSegments.last,
  format: 'bin',
  sizeBytes: size,
  contentSha256: hash,
  localPath: source.path,
  availableOnDeviceIds: const ['a'],
);

Future<_ResponseData> _read(Uri uri, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final statusCode = response.statusCode;
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final body = await response.fold<List<int>>([], (all, part) => all..addAll(part));
    return _ResponseData(statusCode: statusCode, contentRange: contentRange, body: body);
  } finally {
    client.close(force: true);
  }
}

class _ResponseData {
  const _ResponseData({required this.statusCode, required this.contentRange, required this.body});

  final int statusCode;
  final String? contentRange;
  final List<int> body;
}
