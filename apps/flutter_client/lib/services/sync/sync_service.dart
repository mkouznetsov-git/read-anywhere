import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/book.dart';
import '../../models/manifest.dart';
import '../../models/sync_settings.dart';
import '../storage_service.dart';
import 'merge.dart';
import 'relay_client.dart';

const _uuid = Uuid();
const _defaultChunkSize = 256 * 1024; // JSON/base64-safe for the MVP relay.

class FileTransferSnapshot {
  const FileTransferSnapshot({
    required this.transferId,
    required this.bookId,
    required this.direction,
    required this.statusText,
    this.fileName = '',
    this.peerDeviceId = '',
    this.progressPercent = 0,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.active = false,
    this.error,
  });

  final String transferId;
  final String bookId;
  final String direction; // download | upload
  final String statusText;
  final String fileName;
  final String peerDeviceId;
  final double progressPercent;
  final int transferredBytes;
  final int totalBytes;
  final bool active;
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;

  FileTransferSnapshot copyWith({
    String? statusText,
    String? fileName,
    String? peerDeviceId,
    double? progressPercent,
    int? transferredBytes,
    int? totalBytes,
    bool? active,
    String? error,
    bool clearError = false,
  }) {
    return FileTransferSnapshot(
      transferId: transferId,
      bookId: bookId,
      direction: direction,
      statusText: statusText ?? this.statusText,
      fileName: fileName ?? this.fileName,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      progressPercent: progressPercent ?? this.progressPercent,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      active: active ?? this.active,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SyncStateSnapshot {
  const SyncStateSnapshot({
    required this.connected,
    required this.statusText,
    this.relayUrl,
    this.sentEvents = 0,
    this.receivedEvents = 0,
    this.logLines = const [],
    this.fileTransfers = const {},
  });

  final bool connected;
  final String statusText;
  final String? relayUrl;
  final int sentEvents;
  final int receivedEvents;
  final List<String> logLines;
  final Map<String, FileTransferSnapshot> fileTransfers;

  SyncStateSnapshot copyWith({
    bool? connected,
    String? statusText,
    String? relayUrl,
    int? sentEvents,
    int? receivedEvents,
    List<String>? logLines,
    Map<String, FileTransferSnapshot>? fileTransfers,
  }) {
    return SyncStateSnapshot(
      connected: connected ?? this.connected,
      statusText: statusText ?? this.statusText,
      relayUrl: relayUrl ?? this.relayUrl,
      sentEvents: sentEvents ?? this.sentEvents,
      receivedEvents: receivedEvents ?? this.receivedEvents,
      logLines: logLines ?? this.logLines,
      fileTransfers: fileTransfers ?? this.fileTransfers,
    );
  }

  FileTransferSnapshot? downloadForBook(String bookId) => fileTransfers[bookId];
}

class SyncService {
  SyncService(this._storage);

  final StorageService _storage;
  final state = ValueNotifier<SyncStateSnapshot>(
    const SyncStateSnapshot(connected: false, statusText: 'Не подключено'),
  );

  RelayClient? _client;
  StreamSubscription<void>? _incomingSubscription;
  final _manifestChanges = StreamController<LibraryManifest>.broadcast();
  final _downloadsByTransferId = <String, _DownloadSession>{};
  final _uploadLocks = <String>{};

  Stream<LibraryManifest> get manifestChanges => _manifestChanges.stream;

  Future<void> connect({required String relayUrl}) async {
    await disconnect();
    _setState(
      state.value.copyWith(
        connected: false,
        statusText: 'Подключение...',
        relayUrl: relayUrl,
      ),
    );

    final manifest = await _storage.loadManifest();
    final uri = Uri.parse(relayUrl.trim());
    final client = RelayClient(
      relayUri: uri,
      accountId: manifest.accountId,
      deviceId: manifest.deviceId,
    );
    _client = client;
    _incomingSubscription = client.incoming
        .asyncMap((envelope) async {
          await _handleIncomingEnvelope(envelope);
        })
        .listen(
      (_) {},
      onError: (error) {
        _appendLog('Ошибка relay: $error');
        _setState(state.value.copyWith(connected: false, statusText: 'Ошибка'));
      },
    );

    await client.connect();
    await _storage.saveSyncSettings(SyncSettings(relayUrl: relayUrl.trim()));
    _appendLog('Подключено к $relayUrl');
    _setState(
      state.value.copyWith(connected: true, statusText: 'Подключено'),
    );
    await broadcastLibrarySnapshot(reason: 'connected');
  }

  Future<void> disconnect() async {
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    final client = _client;
    _client = null;
    await client?.dispose();
    if (state.value.connected) {
      _appendLog('Отключено');
    }
    _setState(state.value.copyWith(connected: false, statusText: 'Не подключено'));
  }

  Future<bool> broadcastLibrarySnapshot({required String reason}) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;

    final manifest = await _storage.loadManifest();
    final envelope = SyncEnvelope(
      type: 'library_snapshot',
      accountId: manifest.accountId,
      deviceId: manifest.deviceId,
      payload: {
        'reason': reason,
        'manifest': manifest.toSyncJson(),
      },
    );

    try {
      client.send(envelope);
      _appendLog('Отправлен snapshot: $reason');
      _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
      return true;
    } catch (error) {
      _appendLog('Не удалось отправить snapshot: $error');
      _setState(state.value.copyWith(connected: false, statusText: 'Ошибка'));
      return false;
    }
  }

  Future<bool> requestBookFile(BookRecord book) async {
    final client = _client;
    if (client == null || !state.value.connected) {
      _appendLog('Нельзя скачать ${book.title}: нет подключения к relay');
      return false;
    }
    if (book.isDownloaded) {
      _appendLog('${book.title} уже скачана на этом устройстве');
      return false;
    }

    final manifest = await _storage.loadManifest();
    final transferId = 'transfer-${_uuid.v4()}';
    final session = _DownloadSession(
      transferId: transferId,
      bookId: book.id,
      fileName: book.fileName,
      format: book.format,
      expectedSha256: book.contentSha256,
      expectedBytes: book.sizeBytes,
    );
    _downloadsByTransferId[transferId] = session;
    _setDownloadSnapshot(
      FileTransferSnapshot(
        transferId: transferId,
        bookId: book.id,
        direction: 'download',
        fileName: book.fileName,
        statusText: 'Ищем устройство с файлом...',
        active: true,
        totalBytes: book.sizeBytes,
      ),
    );

    final envelope = SyncEnvelope(
      type: 'book_file_requested',
      accountId: manifest.accountId,
      deviceId: manifest.deviceId,
      payload: {
        'transferId': transferId,
        'bookId': book.id,
        'requestingDeviceId': manifest.deviceId,
        'fileName': book.fileName,
        'expectedSha256': book.contentSha256,
        'expectedSizeBytes': book.sizeBytes,
        'preferredChunkSize': _defaultChunkSize,
      },
    );
    client.send(envelope);
    _appendLog('Запрошен файл: ${book.title}');
    _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
    return true;
  }

  Future<void> _handleIncomingEnvelope(SyncEnvelope envelope) async {
    final local = await _storage.loadManifest();
    if (envelope.accountId != local.accountId) {
      _appendLog('Пропущено событие другого аккаунта: ${envelope.accountId}');
      return;
    }
    if (envelope.deviceId == local.deviceId) return;

    if (envelope.type == 'peer_joined') {
      _appendLog('Подключилось другое устройство: ${envelope.deviceId}');
      await broadcastLibrarySnapshot(reason: 'peer_joined');
      return;
    }

    if (envelope.type == 'peer_left') {
      _appendLog('Отключилось другое устройство: ${envelope.deviceId}');
      return;
    }

    if (envelope.type == 'error') {
      _appendLog('Relay вернул ошибку: ${envelope.payload['message'] ?? envelope.payload}');
      return;
    }

    switch (envelope.type) {
      case 'library_snapshot':
        await _handleLibrarySnapshot(envelope, local);
        break;
      case 'book_file_requested':
        await _handleBookFileRequested(envelope, local);
        break;
      case 'book_file_offer':
        await _handleBookFileOffer(envelope, local);
        break;
      case 'book_file_accept':
        unawaited(_handleBookFileAccept(envelope, local));
        break;
      case 'book_file_chunk':
        await _handleBookFileChunk(envelope, local);
        break;
      case 'book_file_error':
        await _handleBookFileError(envelope, local);
        break;
      default:
        _appendLog('Неизвестное событие: ${envelope.type}');
    }
  }

  Future<void> _handleLibrarySnapshot(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payloadManifest = envelope.payload['manifest'];
    if (payloadManifest is! Map) {
      _appendLog('Некорректный snapshot');
      return;
    }

    final remote = LibraryManifest.fromJson(Map<String, dynamic>.from(payloadManifest));
    final merged = mergeManifests(local, remote);
    await _storage.saveManifest(merged);
    _manifestChanges.add(merged);
    _appendLog(
      'Принят snapshot от ${remote.deviceName} — книг: ${remote.books.length}',
    );
    _setState(
      state.value.copyWith(receivedEvents: state.value.receivedEvents + 1),
    );
  }

  Future<void> _handleBookFileRequested(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    final requestingDeviceId = payload['requestingDeviceId'] as String?;
    if (requestingDeviceId == null || requestingDeviceId == local.deviceId) return;

    final bookId = payload['bookId'] as String?;
    final transferId = payload['transferId'] as String?;
    if (bookId == null || transferId == null) return;

    final book = _findBook(local, bookId);
    if (book == null || book.localPath == null) return;
    final file = File(book.localPath!);
    if (!await file.exists()) return;

    final chunkSize = math.min(
      (payload['preferredChunkSize'] as num?)?.toInt() ?? _defaultChunkSize,
      _defaultChunkSize,
    );

    _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_offer',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'fileName': book.fileName,
          'format': book.format,
          'sizeBytes': await file.length(),
          'sha256': book.contentSha256,
          'chunkSize': chunkSize,
        },
      ),
    );
    _appendLog('Предложен файл: ${book.title} → $requestingDeviceId');
  }

  Future<void> _handleBookFileOffer(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final sourceDeviceId = payload['sourceDeviceId'] as String?;
    if (transferId == null || sourceDeviceId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null || session.sourceDeviceId != null) return;

    final offeredSha = payload['sha256'] as String?;
    if (offeredSha != null && offeredSha != session.expectedSha256) {
      _appendLog('Отклонён offer: SHA-256 не совпадает');
      return;
    }

    final appDir = await _storage.appDir();
    final incomingDir = Directory(p.join(appDir.path, 'incoming'));
    if (!await incomingDir.exists()) {
      await incomingDir.create(recursive: true);
    }
    final tempFile = File(p.join(incomingDir.path, '$transferId.part'));
    if (await tempFile.exists()) await tempFile.delete();
    await tempFile.create(recursive: true);

    session
      ..sourceDeviceId = sourceDeviceId
      ..tempFile = tempFile
      ..chunkSize = (payload['chunkSize'] as num?)?.toInt() ?? _defaultChunkSize;

    _setDownloadSnapshot(
      state.value.downloadForBook(session.bookId)!.copyWith(
            statusText: 'Источник найден, начинаем скачивание...',
            peerDeviceId: sourceDeviceId,
            active: true,
            clearError: true,
          ),
    );

    _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_accept',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': session.bookId,
          'sourceDeviceId': sourceDeviceId,
          'requestingDeviceId': local.deviceId,
          'chunkSize': session.chunkSize,
        },
      ),
    );
    _appendLog('Принят источник файла: $sourceDeviceId');
  }

  Future<void> _handleBookFileAccept(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final bookId = payload['bookId'] as String?;
    final requestingDeviceId = payload['requestingDeviceId'] as String?;
    if (transferId == null || bookId == null || requestingDeviceId == null) return;
    if (!_uploadLocks.add(transferId)) return;

    try {
      await _sendFileChunks(
        local: local,
        transferId: transferId,
        bookId: bookId,
        requestingDeviceId: requestingDeviceId,
        chunkSize: (payload['chunkSize'] as num?)?.toInt() ?? _defaultChunkSize,
      );
    } finally {
      _uploadLocks.remove(transferId);
    }
  }

  Future<void> _sendFileChunks({
    required LibraryManifest local,
    required String transferId,
    required String bookId,
    required String requestingDeviceId,
    required int chunkSize,
  }) async {
    final book = _findBook(await _storage.loadManifest(), bookId);
    if (book == null || book.localPath == null) {
      _sendFileError(local, transferId, bookId, requestingDeviceId, 'Файл не найден у источника');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      _sendFileError(local, transferId, bookId, requestingDeviceId, 'Локальный файл отсутствует');
      return;
    }

    final size = await file.length();
    final safeChunkSize = chunkSize.clamp(64 * 1024, _defaultChunkSize).toInt();
    final totalChunks = (size / safeChunkSize).ceil();
    final uploadKey = 'upload:$transferId';

    _updateTransferByKey(
      uploadKey,
      FileTransferSnapshot(
        transferId: transferId,
        bookId: bookId,
        direction: 'upload',
        fileName: book.fileName,
        peerDeviceId: requestingDeviceId,
        statusText: 'Отправка файла...',
        active: true,
        totalBytes: size,
      ),
    );

    final raf = await file.open(mode: FileMode.read);
    var chunkIndex = 0;
    var sentBytes = 0;
    try {
      while (true) {
        final data = await raf.read(safeChunkSize);
        if (data.isEmpty) break;
        sentBytes += data.length;
        _sendEnvelope(
          SyncEnvelope(
            type: 'book_file_chunk',
            accountId: local.accountId,
            deviceId: local.deviceId,
            payload: {
              'transferId': transferId,
              'bookId': bookId,
              'sourceDeviceId': local.deviceId,
              'requestingDeviceId': requestingDeviceId,
              'chunkIndex': chunkIndex,
              'totalChunks': totalChunks,
              'offset': chunkIndex * safeChunkSize,
              'totalBytes': size,
              'sha256': book.contentSha256,
              'dataBase64': base64Encode(data),
            },
          ),
        );
        final progress = size == 0 ? 100.0 : (sentBytes / size) * 100;
        _updateTransferByKey(
          uploadKey,
          state.value.fileTransfers[uploadKey]!.copyWith(
                progressPercent: progress.clamp(0, 100).toDouble(),
                transferredBytes: sentBytes,
                statusText: 'Отправка: ${progress.clamp(0, 100).toStringAsFixed(1)}%',
              ),
        );
        chunkIndex += 1;
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      _updateTransferByKey(
        uploadKey,
        state.value.fileTransfers[uploadKey]!.copyWith(
              progressPercent: 100,
              transferredBytes: size,
              statusText: 'Файл отправлен',
              active: false,
            ),
      );
      _appendLog('Файл отправлен: ${book.title}');
    } catch (error) {
      _updateTransferByKey(
        uploadKey,
        state.value.fileTransfers[uploadKey]!.copyWith(
              statusText: 'Ошибка отправки',
              active: false,
              error: '$error',
            ),
      );
      _sendFileError(local, transferId, bookId, requestingDeviceId, 'Ошибка отправки: $error');
    } finally {
      await raf.close();
    }
  }

  Future<void> _handleBookFileChunk(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    if (session.sourceDeviceId != null && payload['sourceDeviceId'] != session.sourceDeviceId) {
      return;
    }

    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (chunkIndex == null) return;
    if (chunkIndex != session.expectedChunkIndex) {
      await _failDownload(
        session,
        'Нарушен порядок chunks: ожидали ${session.expectedChunkIndex}, получили $chunkIndex',
      );
      return;
    }

    final tempFile = session.tempFile;
    final dataBase64 = payload['dataBase64'] as String?;
    if (tempFile == null || dataBase64 == null) return;

    try {
      final data = base64Decode(dataBase64);
      await tempFile.writeAsBytes(data, mode: FileMode.append, flush: false);
      session
        ..expectedChunkIndex += 1
        ..receivedBytes += data.length
        ..totalChunks = (payload['totalChunks'] as num?)?.toInt()
        ..expectedBytes = (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes;

      final totalBytes = session.expectedBytes;
      final progress = totalBytes <= 0 ? 0.0 : (session.receivedBytes / totalBytes) * 100;
      _setDownloadSnapshot(
        state.value.downloadForBook(session.bookId)!.copyWith(
              statusText: 'Скачивание: ${progress.clamp(0, 100).toStringAsFixed(1)}%',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: totalBytes,
              active: true,
            ),
      );

      final totalChunks = session.totalChunks;
      if (totalChunks != null && session.expectedChunkIndex >= totalChunks) {
        await _finalizeDownload(session);
      }
    } catch (error) {
      await _failDownload(session, 'Ошибка получения chunk: $error');
    }
  }

  Future<void> _finalizeDownload(_DownloadSession session) async {
    final tempFile = session.tempFile;
    if (tempFile == null || !await tempFile.exists()) {
      await _failDownload(session, 'Временный файл не найден');
      return;
    }

    _setDownloadSnapshot(
      state.value.downloadForBook(session.bookId)!.copyWith(
            statusText: 'Проверяем SHA-256...',
            active: true,
          ),
    );

    final actualSha = (await sha256.bind(tempFile.openRead()).first).toString();
    if (actualSha != session.expectedSha256) {
      await _failDownload(
        session,
        'SHA-256 не совпадает: ожидали ${session.expectedSha256}, получили $actualSha',
      );
      return;
    }

    final extension = session.format.isEmpty ? 'book' : session.format;
    final destination = File(p.join((await _storage.booksDir()).path, '${session.expectedSha256}.$extension'));
    if (await destination.exists()) await destination.delete();
    await tempFile.rename(destination.path);

    final manifest = await _storage.markBookDownloaded(
      bookId: session.bookId,
      localPath: destination.path,
    );
    _manifestChanges.add(manifest);
    _downloadsByTransferId.remove(session.transferId);

    _setDownloadSnapshot(
      state.value.downloadForBook(session.bookId)!.copyWith(
            statusText: 'Скачано и проверено',
            progressPercent: 100,
            transferredBytes: session.expectedBytes,
            totalBytes: session.expectedBytes,
            active: false,
            clearError: true,
          ),
    );
    _appendLog('Файл скачан и проверен: ${session.fileName}');
    await broadcastLibrarySnapshot(reason: 'book_file_downloaded');
  }

  Future<void> _handleBookFileError(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    await _failDownload(session, payload['message'] as String? ?? 'Ошибка передачи файла');
  }

  Future<void> _failDownload(_DownloadSession session, String message) async {
    try {
      final tempFile = session.tempFile;
      if (tempFile != null && await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      // Best effort cleanup.
    }
    _downloadsByTransferId.remove(session.transferId);
    final existing = state.value.downloadForBook(session.bookId);
    if (existing != null) {
      _setDownloadSnapshot(
        existing.copyWith(
          statusText: 'Ошибка скачивания',
          active: false,
          error: message,
        ),
      );
    }
    _appendLog('Ошибка скачивания ${session.fileName}: $message');
  }

  void _sendFileError(
    LibraryManifest local,
    String transferId,
    String bookId,
    String requestingDeviceId,
    String message,
  ) {
    _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_error',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'message': message,
        },
      ),
    );
  }

  BookRecord? _findBook(LibraryManifest manifest, String bookId) {
    for (final book in manifest.books) {
      if (book.id == bookId) return book;
    }
    return null;
  }

  void _sendEnvelope(SyncEnvelope envelope) {
    final client = _client;
    if (client == null || !state.value.connected) {
      throw StateError('RelayClient is not connected');
    }
    client.send(envelope);
    _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
  }

  void _setDownloadSnapshot(FileTransferSnapshot snapshot) {
    _updateTransferByKey(snapshot.bookId, snapshot);
  }

  void _updateTransferByKey(String key, FileTransferSnapshot snapshot) {
    final updated = Map<String, FileTransferSnapshot>.from(state.value.fileTransfers);
    updated[key] = snapshot;
    _setState(state.value.copyWith(fileTransfers: Map.unmodifiable(updated)));
  }

  void _appendLog(String line) {
    final timestamp = DateTime.now().toLocal().toIso8601String().substring(11, 19);
    final updated = ['[$timestamp] $line', ...state.value.logLines];
    _setState(state.value.copyWith(logLines: updated.take(30).toList()));
  }

  void _setState(SyncStateSnapshot snapshot) {
    state.value = snapshot;
  }

  Future<void> dispose() async {
    await disconnect();
    await _manifestChanges.close();
    state.dispose();
  }
}

class _DownloadSession {
  _DownloadSession({
    required this.transferId,
    required this.bookId,
    required this.fileName,
    required this.format,
    required this.expectedSha256,
    required this.expectedBytes,
  });

  final String transferId;
  final String bookId;
  final String fileName;
  final String format;
  final String expectedSha256;
  int expectedBytes;

  String? sourceDeviceId;
  File? tempFile;
  int chunkSize = _defaultChunkSize;
  int expectedChunkIndex = 0;
  int receivedBytes = 0;
  int? totalChunks;
}
