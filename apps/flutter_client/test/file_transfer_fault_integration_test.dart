import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/connection_manager.dart';
import 'package:readarc/services/sync/e2e_crypto.dart';
import 'package:readarc/services/sync/relay_client.dart';
import 'package:readarc/services/sync/sync_service.dart';

const _chunkSize = 64 * 1024;
const _serviceOptions = SyncServiceOptions(
  chunkSize: _chunkSize,
  minimumChunkSize: _chunkSize,
  downloadOfferTimeout: Duration(seconds: 3),
  downloadIdleTimeout: Duration(seconds: 3),
  uploadAckTimeout: Duration(milliseconds: 500),
  uploadRetryDelay: Duration(milliseconds: 20),
  enableDirectTransfer: false,
);

void main() {
  test('real relay transfers multiple encrypted chunks and publishes only after SHA-256', () async {
    final scenario = await _TransferScenario.start();
    addTearDown(scenario.dispose);

    await scenario.download();
    await scenario.expectCompleted();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('duplicate, premature and tampered frames are rejected without corrupting the transfer', () async {
    final scenario = await _TransferScenario.start(
      sourceFaults: const _BinaryFaults(duplicate: true, premature: true, tamperThenRecover: true),
    );
    addTearDown(scenario.dispose);

    await scenario.download();
    await scenario.expectCompleted();
    expect(scenario.syncB.state.value.logLines.any((line) => line.contains('преждевременный binary chunk')), isTrue);
    expect(scenario.syncB.state.value.logLines.any((line) => line.contains('Ошибка binary transfer')), isTrue);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('receiver process restart resumes from its durable relay chunk boundary', () async {
    final scenario = await _TransferScenario.start(
      sourceFaults: const _BinaryFaults(delay: Duration(milliseconds: 30)),
    );
    addTearDown(scenario.dispose);

    await scenario.download();
    final partialLength = await scenario.waitForPartial();
    await scenario.restartReceiver();
    await scenario.expectCompleted();
    expect(partialLength, greaterThanOrEqualTo(_chunkSize));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('source process restart makes the receiver re-request and resume automatically', () async {
    final scenario = await _TransferScenario.start(
      sourceFaults: const _BinaryFaults(delay: Duration(milliseconds: 30)),
    );
    addTearDown(scenario.dispose);

    await scenario.download();
    final partialLength = await scenario.waitForPartial();
    await scenario.restartSource();
    await scenario.expectCompleted();
    expect(partialLength, greaterThanOrEqualTo(_chunkSize));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('relay process restart resumes the transfer instead of restarting the file', () async {
    final scenario = await _TransferScenario.start(
      sourceFaults: const _BinaryFaults(delay: Duration(milliseconds: 30)),
    );
    addTearDown(scenario.dispose);

    await scenario.download();
    final partialLength = await scenario.waitForPartial();
    await scenario.relay.restart();
    await scenario.expectCompleted();
    expect(partialLength, greaterThanOrEqualTo(_chunkSize));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('revoking the receiver aborts an active transfer and never publishes its partial', () async {
    final scenario = await _TransferScenario.start(
      sourceFaults: const _BinaryFaults(delay: Duration(milliseconds: 30)),
    );
    addTearDown(scenario.dispose);

    await scenario.download();
    await scenario.waitForPartial();
    await scenario.storageA.revokeTrustedDevice('b');
    await scenario.syncA.broadcastLibrarySnapshot(reason: 'trusted_device_revoked');
    await _waitFor(() async => !scenario.syncB.state.value.connected, timeout: const Duration(seconds: 5));

    final receiverBook = (await scenario.storageB.loadManifest()).books.single;
    expect(receiverBook.isDownloaded, isFalse);
    expect(await scenario.partialFile.length(), lessThan(scenario.bytes.length));
  }, timeout: const Timeout(Duration(seconds: 20)));
}

class _TransferScenario {
  _TransferScenario._({
    required this.relay,
    required this.directoryA,
    required this.directoryB,
    required this.storageA,
    required this.storageB,
    required this.syncA,
    required this.syncB,
    required this.bytes,
    required this.sourceFaults,
  });

  final _RelayProcess relay;
  final Directory directoryA;
  final Directory directoryB;
  final StorageService storageA;
  final StorageService storageB;
  SyncService syncA;
  SyncService syncB;
  final List<int> bytes;
  final _BinaryFaults sourceFaults;

  static Future<_TransferScenario> start({_BinaryFaults sourceFaults = const _BinaryFaults()}) async {
    final relay = await _RelayProcess.start();
    final directoryA = await Directory.systemTemp.createTemp('readarc-transfer-a-');
    final directoryB = await Directory.systemTemp.createTemp('readarc-transfer-b-');
    final bytes = List<int>.generate(_chunkSize * 5 + 123, (index) => (index * 17 + 11) % 256);
    final sourceFile = File('${directoryA.path}/source.bin');
    await sourceFile.writeAsBytes(bytes, flush: true);
    final key = base64UrlEncode(Uint8List.fromList(List<int>.generate(32, (index) => index + 1))).replaceAll('=', '');
    final hash = sha256.convert(bytes).toString();
    final sourceBook = _book(hash: hash, size: bytes.length, localPath: sourceFile.path);
    final remoteBook = _book(hash: hash, size: bytes.length);
    final storageA = _storage(directoryA, _manifest('a', key, sourceBook));
    final storageB = _storage(directoryB, _manifest('b', key, remoteBook));
    final syncA = SyncService(
      storageA,
      options: _serviceOptions,
      connectionManager: _FastConnectionManager(accountKey: key, faults: sourceFaults),
    );
    final syncB = SyncService(
      storageB,
      options: _serviceOptions,
      connectionManager: _FastConnectionManager(accountKey: key),
    );
    await syncA.connect(relayUrl: relay.url);
    await syncB.connect(relayUrl: relay.url);
    return _TransferScenario._(
      relay: relay,
      directoryA: directoryA,
      directoryB: directoryB,
      storageA: storageA,
      storageB: storageB,
      syncA: syncA,
      syncB: syncB,
      bytes: bytes,
      sourceFaults: sourceFaults,
    );
  }

  File get partialFile => File('${directoryB.path}/incoming/book.part');

  Future<void> download() async {
    final book = (await storageB.loadManifest()).books.single;
    expect(await syncB.requestBookFile(book), isTrue);
  }

  Future<int> waitForPartial() async {
    await _waitFor(
      () async => await partialFile.exists() && await partialFile.length() >= _chunkSize,
      timeout: const Duration(seconds: 5),
    );
    final length = await partialFile.length();
    expect(length, lessThan(bytes.length));
    return length;
  }

  Future<void> restartReceiver() async {
    await syncB.dispose();
    syncB = SyncService(
      storageB,
      options: _serviceOptions,
      connectionManager: _FastConnectionManager(accountKey: (await storageB.loadManifest()).accountEncryptionKey),
    );
    await syncB.connect(relayUrl: relay.url);
  }

  Future<void> restartSource() async {
    await syncA.dispose();
    syncA = SyncService(
      storageA,
      options: _serviceOptions,
      connectionManager: _FastConnectionManager(
        accountKey: (await storageA.loadManifest()).accountEncryptionKey,
        faults: sourceFaults,
      ),
    );
    await syncA.connect(relayUrl: relay.url);
  }

  Future<void> expectCompleted() async {
    await _waitFor(
      () async => (await storageB.loadManifest()).books.single.isDownloaded,
      timeout: const Duration(seconds: 12),
    );
    final book = (await storageB.loadManifest()).books.single;
    expect(book.localPath, isNotNull);
    expect(await File(book.localPath!).readAsBytes(), bytes);
    expect(await partialFile.exists(), isFalse);
  }

  Future<void> dispose() async {
    await syncA.dispose();
    await syncB.dispose();
    await relay.dispose();
    for (final directory in [directoryA, directoryB]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

class _BinaryFaults {
  const _BinaryFaults({
    this.delay = Duration.zero,
    this.duplicate = false,
    this.premature = false,
    this.tamperThenRecover = false,
  });

  final Duration delay;
  final bool duplicate;
  final bool premature;
  final bool tamperThenRecover;
}

class _FastConnectionManager extends ConnectionManager {
  _FastConnectionManager({required this.accountKey, this.faults = const _BinaryFaults()});

  final String accountKey;
  final _BinaryFaults faults;

  @override
  int retryDelaySeconds(int attempt) => 0;

  @override
  RelayClient createClient({required Uri relayUri, required LibraryManifest manifest}) => _FaultRelayClient(
    relayUri: relayUri,
    accountId: manifest.accountId,
    deviceId: manifest.deviceId,
    accountKey: accountKey,
    faults: faults,
  );
}

class _FaultRelayClient extends RelayClient {
  _FaultRelayClient({
    required super.relayUri,
    required super.accountId,
    required super.deviceId,
    required this.accountKey,
    required this.faults,
  });

  final String accountKey;
  final _BinaryFaults faults;
  final _faultedChunks = <String>{};
  bool _closed = false;

  @override
  void sendBinary(RelayBinaryMessage message) {
    unawaited(_sendWithFaults(message));
  }

  Future<void> _sendWithFaults(RelayBinaryMessage message) async {
    if (faults.delay > Duration.zero) await Future<void>.delayed(faults.delay);
    if (_closed) return;
    final chunkIndex = (message.header['chunkIndex'] as num?)?.toInt() ?? -1;
    try {
      if (faults.premature && chunkIndex == 0 && _faultedChunks.add('premature')) {
        final clear = await ReadArcE2eCrypto.decryptBinaryFrame(
          header: message.header,
          cipherBytes: message.body,
          accountEncryptionKey: accountKey,
        );
        final futureHeader = Map<String, dynamic>.from(message.header)
          ..remove('e2ee')
          ..['chunkIndex'] = 1
          ..['offset'] = _chunkSize
          ..['operationId'] = '${message.header['transferId']}:premature-1';
        final future = await ReadArcE2eCrypto.encryptBinaryFrame(
          headerFields: futureHeader,
          clearBytes: clear,
          accountEncryptionKey: accountKey,
        );
        super.sendBinary(RelayBinaryMessage(header: future.header, body: future.cipherBytes));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (faults.tamperThenRecover && chunkIndex == 1 && _faultedChunks.add('tamper')) {
        final corrupted = Uint8List.fromList(message.body);
        corrupted[0] ^= 0xff;
        super.sendBinary(RelayBinaryMessage(header: message.header, body: corrupted));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (_closed) return;
      super.sendBinary(message);
      if (faults.duplicate && chunkIndex == 2 && _faultedChunks.add('duplicate')) {
        super.sendBinary(message);
      }
    } catch (_) {
      // A deliberately interrupted client can close while a delayed frame is
      // pending. The real reconnect path owns recovery; the test transport must
      // not leak an asynchronous error into the runner.
    }
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await super.dispose();
  }
}

class _RelayProcess {
  _RelayProcess._({required this.directory, required this.port});

  final Directory directory;
  final int port;
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  final diagnostics = StringBuffer();

  String get url => 'http://127.0.0.1:$port';

  static Future<_RelayProcess> start() async {
    final directory = await Directory.systemTemp.createTemp('readarc-fault-relay-');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final relay = _RelayProcess._(directory: directory, port: port);
    await relay._startProcess();
    return relay;
  }

  Future<void> restart() async {
    await _stopProcess();
    await _startProcess();
  }

  Future<void> _startProcess() async {
    final root = Directory.current.path.endsWith('apps/flutter_client')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    _process = await Process.start(
      'python3',
      ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: '$root/server/rendezvous_relay',
      environment: {...Platform.environment, 'READARC_RELAY_DATA_DIR': directory.path},
    );
    _stdout = _process!.stdout.transform(utf8.decoder).listen(diagnostics.write);
    _stderr = _process!.stderr.transform(utf8.decoder).listen(diagnostics.write);
    await _waitFor(() async {
      if (await _process!.exitCode.timeout(Duration.zero, onTimeout: () => -999) != -999) {
        throw StateError('relay exited before startup: $diagnostics');
      }
      final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 200);
      try {
        final response = await (await client.getUrl(Uri.parse('$url/health'))).close();
        await response.drain<void>();
        return response.statusCode == HttpStatus.ok;
      } catch (_) {
        return false;
      } finally {
        client.close(force: true);
      }
    }, timeout: const Duration(seconds: 10));
  }

  Future<void> _stopProcess() async {
    final process = _process;
    if (process == null) return;
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    await _stdout?.cancel();
    await _stderr?.cancel();
    _process = null;
  }

  Future<void> dispose() async {
    await _stopProcess();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

StorageService _storage(Directory directory, LibraryManifest manifest) {
  final secrets = _MemorySecretStore();
  return StorageService(
    repository: LibraryRepository(
      appDirectory: () async => directory,
      secretStore: secrets,
      createInitialManifest: () async => manifest,
      normalize: (value) => value,
    ),
    secretStore: secrets,
  );
}

LibraryManifest _manifest(String deviceId, String key, BookRecord book) => LibraryManifest(
  accountId: 'transfer-account',
  accountEncryptionKey: key,
  deviceId: deviceId,
  deviceName: deviceId.toUpperCase(),
  deviceSigningPublicKey: 'public-$deviceId',
  deviceSigningPrivateKey: 'private-$deviceId',
  books: [book],
  trustedDevices: [
    TrustedDeviceRecord(deviceId: 'a', name: 'A', role: 'owner', publicKey: 'public-a'),
    TrustedDeviceRecord(deviceId: 'b', name: 'B', publicKey: 'public-b'),
  ],
);

BookRecord _book({required String hash, required int size, String? localPath}) => BookRecord(
  id: 'book',
  title: 'Fault injection fixture',
  fileName: 'fixture.bin',
  format: 'bin',
  sizeBytes: size,
  contentSha256: hash,
  localPath: localPath,
  availableOnDeviceIds: const ['a'],
);

Future<void> _waitFor(Future<bool> Function() predicate, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
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
