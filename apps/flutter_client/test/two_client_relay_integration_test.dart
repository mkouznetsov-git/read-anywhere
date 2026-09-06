import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  test('two clients exchange progress through a real relay process', () async {
    final root = Directory.current.path.endsWith('apps/flutter_client')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    final relayDirectory = '$root/server/rendezvous_relay';
    final relayData = await Directory.systemTemp.createTemp('readarc-relay-data-');
    final clientAData = await Directory.systemTemp.createTemp('readarc-client-a-');
    final clientBData = await Directory.systemTemp.createTemp('readarc-client-b-');
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();

    final process = await Process.start(
      'python3',
      ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: relayDirectory,
      environment: {...Platform.environment, 'READARC_RELAY_DATA_DIR': relayData.path},
    );
    final diagnostics = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(diagnostics.write);
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(diagnostics.write);

    final key = base64UrlEncode(Uint8List(32)).replaceAll('=', '');
    final secretsA = _MemorySecretStore();
    final secretsB = _MemorySecretStore();
    final storageA = _storage(clientAData, secretsA, _manifest('a', key));
    final storageB = _storage(clientBData, secretsB, _manifest('b', key));
    final syncA = SyncService(storageA);
    final syncB = SyncService(storageB);

    try {
      await _waitForRelay(port, process, diagnostics);
      final relayUrl = 'http://127.0.0.1:$port';
      await syncA.connect(relayUrl: relayUrl);
      await syncB.connect(relayUrl: relayUrl);

      await storageA.updateProgress(bookId: 'book', progressPercent: 67, locator: 'txt:67');
      expect(await syncA.broadcastLibrarySnapshot(reason: 'integration_progress'), isTrue);

      await _waitFor(
        () async => (await storageB.loadManifest()).books.single.progressPercent == 67,
        timeout: const Duration(seconds: 8),
      );
      final received = await storageB.loadManifest();
      expect(received.books.single.progressPercent, 67);
      expect(received.books.single.currentLocator, 'txt:67');
      expect(received.appliedOperationIds, isNotEmpty);
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      for (final directory in [relayData, clientAData, clientBData]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

StorageService _storage(Directory directory, _MemorySecretStore secrets, LibraryManifest initial) => StorageService(
  repository: LibraryRepository(
    appDirectory: () async => directory,
    secretStore: secrets,
    createInitialManifest: () async => initial,
    normalize: (manifest) => manifest,
  ),
  secretStore: secrets,
);

LibraryManifest _manifest(String deviceId, String key) => LibraryManifest(
  accountId: 'integration-account',
  accountEncryptionKey: key,
  deviceId: deviceId,
  deviceName: deviceId.toUpperCase(),
  deviceSigningPublicKey: 'public-$deviceId',
  deviceSigningPrivateKey: 'private-$deviceId',
  books: [
    BookRecord(
      id: 'book',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 1,
      contentSha256: List.filled(64, 'a').join(),
      availableOnDeviceIds: const ['a'],
    ),
  ],
  trustedDevices: [
    TrustedDeviceRecord(deviceId: 'a', name: 'A', role: 'owner', publicKey: 'public-a'),
    TrustedDeviceRecord(deviceId: 'b', name: 'B', publicKey: 'public-b'),
  ],
);

Future<void> _waitForRelay(int port, Process process, StringBuffer diagnostics) async {
  await _waitFor(() async {
    if (await process.exitCode.timeout(Duration.zero, onTimeout: () => -999) != -999) {
      throw StateError('relay exited before startup: $diagnostics');
    }
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 250);
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final response = await request.close().timeout(const Duration(milliseconds: 500));
      await response.drain();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }, timeout: const Duration(seconds: 10));
}

Future<void> _waitFor(Future<bool> Function() predicate, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('condition was not met', timeout);
}

class _MemorySecretStore implements LibrarySecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
