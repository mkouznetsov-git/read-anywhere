import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/services/sync/direct_transfer_server.dart';

void main() {
  late Directory directory;
  late DirectTransferServer server;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('readarc-direct-transfer-');
    server = DirectTransferServer(
      bindAddress: InternetAddress.loopbackIPv4,
      includeLoopback: true,
      streamChunkSize: 16 * 1024,
      streamChunkDelay: const Duration(milliseconds: 2),
    );
  });

  tearDown(() async {
    await server.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('Direct/LAN resumes an interrupted transfer with an exact HTTP range', () async {
    final fixture = await _fixture(directory, 512 * 1024);
    final url = await _shareUrl(server, fixture);

    final firstPart = await _readPrefix(url, minimumBytes: 64 * 1024);
    expect(firstPart.length, lessThan(fixture.bytes.length));

    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=${firstPart.length}-');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes ${firstPart.length}-${fixture.bytes.length - 1}/${fixture.bytes.length}',
      );
      final remainder = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      final completed = [...firstPart, ...remainder];
      expect(completed, fixture.bytes);
      expect(sha256.convert(completed).toString(), fixture.book.contentSha256);
    } finally {
      client.close(force: true);
    }
  });

  test('revocation stops an active Direct/LAN stream and invalidates its token', () async {
    final fixture = await _fixture(directory, 1024 * 1024);
    final url = await _shareUrl(server, fixture);
    final client = HttpClient();
    final received = <int>[];
    try {
      final response = await (await client.getUrl(url)).close();
      await for (final chunk in response) {
        received.addAll(chunk);
        if (received.length >= 64 * 1024) {
          server.revokeAllShares();
        }
      }
      expect(received.length, greaterThanOrEqualTo(64 * 1024));
      expect(received.length, lessThan(fixture.bytes.length));
    } finally {
      client.close(force: true);
    }

    final rejectedClient = HttpClient();
    try {
      final rejected = await (await rejectedClient.getUrl(url)).close();
      expect(rejected.statusCode, HttpStatus.notFound);
      await rejected.drain<void>();
    } finally {
      rejectedClient.close(force: true);
    }
  });
}

Future<({BookRecord book, List<int> bytes})> _fixture(Directory directory, int size) async {
  final bytes = List<int>.generate(size, (index) => (index * 31 + 17) % 256);
  final file = File('${directory.path}/fixture.bin');
  await file.writeAsBytes(bytes, flush: true);
  final hash = sha256.convert(bytes).toString();
  return (
    bytes: bytes,
    book: BookRecord(
      id: 'direct-book',
      title: 'Direct book',
      fileName: 'fixture.bin',
      format: 'bin',
      sizeBytes: bytes.length,
      contentSha256: hash,
      localPath: file.path,
      availableOnDeviceIds: const ['a'],
    ),
  );
}

Future<Uri> _shareUrl(DirectTransferServer server, ({BookRecord book, List<int> bytes}) fixture) async {
  final urls = await server.createShareUrls(book: fixture.book, file: File(fixture.book.localPath!));
  final loopback = urls.where((url) => Uri.parse(url).host == InternetAddress.loopbackIPv4.address);
  expect(loopback, isNotEmpty);
  return Uri.parse(loopback.first);
}

Future<List<int>> _readPrefix(Uri url, {required int minimumBytes}) async {
  final client = HttpClient();
  final bytes = <int>[];
  StreamSubscription<List<int>>? subscription;
  final completed = Completer<void>();
  try {
    final response = await (await client.getUrl(url)).close();
    subscription = response.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length >= minimumBytes && !completed.isCompleted) {
          completed.complete();
          unawaited(subscription?.cancel());
        }
      },
      onError: completed.completeError,
      onDone: () {
        if (!completed.isCompleted) completed.complete();
      },
      cancelOnError: true,
    );
    await completed.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    return bytes;
  } finally {
    client.close(force: true);
  }
}
