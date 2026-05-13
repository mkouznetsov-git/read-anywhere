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
import 'e2e_crypto.dart';
import 'merge.dart';
import 'relay_client.dart';

const _uuid = Uuid();
const _defaultChunkSize = 1024 * 1024; // Binary chunks: 1 MiB keeps Tailscale/Android stable and reduces ACK overhead.

class PairingInvite {
  const PairingInvite({
    required this.code,
    required this.relayUrl,
    required this.expiresAt,
    required this.inviteLink,
    required this.ownerDeviceName,
    required this.accountEncryptionKey,
  });

  final String code;
  final String relayUrl;
  final DateTime expiresAt;
  final String inviteLink;
  final String ownerDeviceName;
  final String accountEncryptionKey;

  String get displayCode => '${code.substring(0, 3)}-${code.substring(3)}';

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  bool get isNearExpiry => DateTime.now().toUtc().add(const Duration(seconds: 20)).isAfter(expiresAt);
}


class PairingClaimResult {
  const PairingClaimResult({
    required this.accountId,
    required this.relayUrl,
    required this.ownerDeviceId,
    required this.ownerDeviceName,
    required this.accountEncryptionKey,
  });

  final String accountId;
  final String relayUrl;
  final String ownerDeviceId;
  final String ownerDeviceName;
  final String accountEncryptionKey;
}

class _ParsedPairingInput {
  const _ParsedPairingInput({
    required this.code,
    this.relayUrl,
    this.accountEncryptionKey,
    this.ownerDeviceName,
    this.ownerDevicePublicKey,
    this.accountId,
    this.ownerDeviceId,
    this.expiresAt,
  });

  final String code;
  final String? relayUrl;
  final String? accountEncryptionKey;
  final String? ownerDeviceName;
  final String? ownerDevicePublicKey;
  final String? accountId;
  final String? ownerDeviceId;
  final DateTime? expiresAt;

  bool get hasEmbeddedAccountInvite =>
      (accountId?.isNotEmpty ?? false) &&
      (ownerDeviceId?.isNotEmpty ?? false) &&
      (accountEncryptionKey?.isNotEmpty ?? false);

  bool get embeddedInviteExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);
}

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
    this.onlinePeerDeviceIds = const [],
  });

  final bool connected;
  final String statusText;
  final String? relayUrl;
  final int sentEvents;
  final int receivedEvents;
  final List<String> logLines;
  final Map<String, FileTransferSnapshot> fileTransfers;
  final List<String> onlinePeerDeviceIds;

  SyncStateSnapshot copyWith({
    bool? connected,
    String? statusText,
    String? relayUrl,
    int? sentEvents,
    int? receivedEvents,
    List<String>? logLines,
    Map<String, FileTransferSnapshot>? fileTransfers,
    List<String>? onlinePeerDeviceIds,
  }) {
    return SyncStateSnapshot(
      connected: connected ?? this.connected,
      statusText: statusText ?? this.statusText,
      relayUrl: relayUrl ?? this.relayUrl,
      sentEvents: sentEvents ?? this.sentEvents,
      receivedEvents: receivedEvents ?? this.receivedEvents,
      logLines: logLines ?? this.logLines,
      fileTransfers: fileTransfers ?? this.fileTransfers,
      onlinePeerDeviceIds: onlinePeerDeviceIds ?? this.onlinePeerDeviceIds,
    );
  }

  FileTransferSnapshot? downloadForBook(String bookId) => fileTransfers[bookId];

  bool hasOnlineStorageFor(BookRecord book) {
    final online = onlinePeerDeviceIds.toSet();
    return book.availableOnDeviceIds.any(online.contains);
  }
}

class SyncService {
  SyncService(this._storage);

  final StorageService _storage;
  final state = ValueNotifier<SyncStateSnapshot>(
    const SyncStateSnapshot(connected: false, statusText: 'Не подключено'),
  );

  RelayClient? _client;
  StreamSubscription<void>? _incomingSubscription;
  StreamSubscription<void>? _binarySubscription;
  final _manifestChanges = StreamController<LibraryManifest>.broadcast();
  final _downloadsByTransferId = <String, _DownloadSession>{};
  final _uploadAckWaiters = <String, Completer<void>>{};
  final _uploadLocks = <String>{};
  final _cancelledTransfers = <String>{};
  final _seenSecureEventIds = <String, DateTime>{};
  // Sprint 27: relay can keep encrypted metadata events for offline devices.
  // Keep replay protection aligned with the relay TTL while still rejecting
  // duplicate eventIds inside the active window.
  static const _replayWindow = Duration(days: 30);

  Timer? _reconnectTimer;
  Timer? _healthTimer;
  bool _manualDisconnect = true;
  bool _reconnectInProgress = false;
  bool _relayUnavailableLogged = false;
  int _reconnectAttempt = 0;
  String? _lastRelayUrl;

  HttpServer? _directFileServer;
  int? _directFileServerPort;
  final _directShares = <String, _DirectFileShare>{};

  Stream<LibraryManifest> get manifestChanges => _manifestChanges.stream;

  /// Start persistent reconnect loop without requiring the first connection to
  /// succeed. This is used on app startup when autoConnect=true and the
  /// Personal Hub/relay is still offline.
  void startAutoReconnect({required String relayUrl}) {
    if (relayUrl.trim().isEmpty || _manualDisconnect == false && _lastRelayUrl == relayUrl && _reconnectTimer != null) {
      return;
    }
    _manualDisconnect = false;
    _lastRelayUrl = relayUrl;
    _reconnectAttempt = 0;
    _appendRelayUnavailableLogOnce();
    _setState(state.value.copyWith(
      connected: false,
      relayUrl: relayUrl,
      statusText: 'Relay недоступен. Переподключаемся...',
    ));
    _scheduleReconnect(immediate: true);
  }

  Future<void> connect({required String relayUrl}) async {
    _manualDisconnect = false;
    _lastRelayUrl = relayUrl;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await disconnect(manual: false);
    _setState(
      state.value.copyWith(
        connected: false,
        statusText: 'Подключение...',
        relayUrl: relayUrl,
      ),
    );

    final manifest = await _storage.loadManifest();
    if (manifest.isCurrentDeviceRevoked) {
      _setState(state.value.copyWith(
        connected: false,
        statusText: 'Доступ этого устройства отозван',
        relayUrl: relayUrl,
      ));
      throw StateError('Доступ этого устройства к аккаунту отозван');
    }
    await _probeRelayHealth(relayUrl, timeout: const Duration(seconds: 5));
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
        unawaited(_handleRelayDisconnected(error));
      },
    );
    _binarySubscription = client.binaryIncoming
        .asyncMap((message) async {
          await _handleIncomingBinaryFrame(message);
        })
        .listen(
      (_) {},
      onError: (error) {
        unawaited(_handleRelayDisconnected(error));
      },
    );

    try {
      await client.connect();
    } catch (error) {
      await disconnect(manual: false);
      if (!_reconnectInProgress) {
        _appendRelayUnavailableLogOnce();
        _scheduleReconnect();
      }
      rethrow;
    }
    _reconnectAttempt = 0;
    _relayUnavailableLogged = false;
    _appendLog('Подключено к $relayUrl');
    _setState(
      state.value.copyWith(connected: true, statusText: 'Подключено'),
    );
    _startHealthMonitor(relayUrl);
    unawaited(_ensureDirectFileServer());

    await refreshMetadata(reason: 'connected');
    _scheduleStartupMetadataRefresh(client);
  }

  Future<void> disconnect({bool manual = true}) async {
    _healthTimer?.cancel();
    _healthTimer = null;
    if (manual) {
      _manualDisconnect = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    await _binarySubscription?.cancel();
    _binarySubscription = null;
    final client = _client;
    _client = null;
    await client?.dispose();
    if (manual && state.value.connected) {
      _appendLog('Отключено');
    }
    _setState(state.value.copyWith(
      connected: false,
      statusText: manual ? 'Не подключено' : 'Relay недоступен. Переподключаемся...',
      onlinePeerDeviceIds: const [],
    ));
  }

  Future<void> _handleRelayDisconnected(Object error) async {
    if (_manualDisconnect) return;
    await disconnect(manual: false);
    _appendRelayUnavailableLogOnce();
    _scheduleReconnect();
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_manualDisconnect || _reconnectInProgress) return;
    final relayUrl = _lastRelayUrl;
    if (relayUrl == null || relayUrl.trim().isEmpty) return;
    _reconnectTimer?.cancel();
    final seconds = immediate ? 0 : _reconnectDelaySeconds(_reconnectAttempt);
    _setState(state.value.copyWith(
      connected: false,
      statusText: seconds <= 0 ? 'Relay недоступен. Переподключаемся...' : 'Relay недоступен. Повтор через ${seconds}с',
      relayUrl: relayUrl,
    ));
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_attemptReconnect(relayUrl));
    });
  }

  int _reconnectDelaySeconds(int attempt) {
    // Keep retry/health traffic modest, but detect recovery quickly.
    // After the first two quick attempts we probe every 5 seconds.
    const delays = [2, 2, 5, 5, 5, 5];
    return delays[attempt.clamp(0, delays.length - 1).toInt()];
  }

  void _appendRelayUnavailableLogOnce() {
    if (_relayUnavailableLogged) return;
    _relayUnavailableLogged = true;
    _appendLog('Relay недоступен. Автопереподключение включено.');
  }

  void _startHealthMonitor(String relayUrl) {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_checkRelayHealth(relayUrl));
    });
  }

  Future<void> _checkRelayHealth(String relayUrl) async {
    if (_manualDisconnect || !state.value.connected) return;
    try {
      await _probeRelayHealth(relayUrl, timeout: const Duration(seconds: 4));
    } catch (error) {
      await _handleRelayDisconnected(error);
    }
  }

  Future<void> _probeRelayHealth(String relayUrl, {required Duration timeout}) async {
    final uri = _buildEndpointUri(relayUrl, '/health');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _attemptReconnect(String relayUrl) async {
    if (_manualDisconnect || _reconnectInProgress) return;
    _reconnectInProgress = true;
    try {
      _reconnectAttempt += 1;
      await connect(relayUrl: relayUrl);
      _appendLog('Автопереподключение выполнено');
    } catch (_) {
      // Не пишем каждую неудачную попытку в журнал: иначе он быстро
      // превращается в шум при выключенном hub/relay. Текущий статус
      // виден по иконке и строке состояния.
      _reconnectInProgress = false;
      _scheduleReconnect();
      return;
    }
    _reconnectInProgress = false;
  }

  Future<void> refreshMetadata({required String reason}) async {
    await requestLibrarySnapshot(reason: '$reason/request');
    await broadcastLibrarySnapshot(reason: '$reason/snapshot');
  }

  void _scheduleStartupMetadataRefresh(RelayClient client) {
    for (final delay in const [
      Duration(milliseconds: 600),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ]) {
      unawaited(Future<void>.delayed(delay, () async {
        if (_client != client || !state.value.connected) return;
        await refreshMetadata(reason: 'startup_retry_${delay.inMilliseconds}ms');
      }));
    }
  }

  Future<bool> broadcastLibrarySnapshot({required String reason}) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;

    final manifest = await _storage.touchCurrentDevice();
    final envelope = SyncEnvelope(
      type: 'library_snapshot',
      accountId: manifest.accountId,
      deviceId: manifest.deviceId,
      payload: {
        'reason': reason,
        'manifest': manifest.toSyncJson(),
      },
    );

    return _sendEnvelope(envelope, logLabel: 'Отправлен E2E snapshot: $reason');
  }

  Future<bool> requestLibrarySnapshot({required String reason}) async {
    final manifest = await _storage.loadManifest();
    return _sendEnvelope(
      SyncEnvelope(
        type: 'library_snapshot_requested',
        accountId: manifest.accountId,
        deviceId: manifest.deviceId,
        payload: {
          'reason': reason,
          'requestingDeviceId': manifest.deviceId,
        },
      ),
      logLabel: 'Запрошен snapshot: $reason',
    );
  }

  Future<PairingInvite> createPairingInvite({
    required SyncSettings settings,
    Duration ttl = const Duration(minutes: 5),
  }) async {
    _validateEndpointForPairing(settings);
    final manifest = await _storage.loadManifest();
    final uri = _buildEndpointUri(settings.effectiveRelayUrl, '/pairing/start');
    final response = await _postJson(uri, {
      'accountId': manifest.accountId,
      'ownerDeviceId': manifest.deviceId,
      'ownerDeviceName': manifest.deviceName,
      'ownerDevicePublicKey': manifest.deviceSigningPublicKey,
      // Transitional fallback for the 6-digit code path. QR/invite links carry
      // this key client-to-client, so a relay only has to see it when the user
      // chooses manual code entry instead of QR.
      'accountEncryptionKey': manifest.accountEncryptionKey,
      'relayUrl': settings.effectiveRelayUrl,
      'expiresSeconds': ttl.inSeconds,
    });
    if (response['ok'] != true) {
      throw StateError(response['message']?.toString() ?? 'Relay не создал pairing-код');
    }
    final code = _normalizePairingCode(response['code']?.toString() ?? '');
    if (code.length != 6) {
      throw StateError('Relay вернул некорректный pairing-код');
    }
    final expiresAtSeconds = (response['expiresAt'] as num?)?.toDouble();
    final expiresAt = expiresAtSeconds == null
        ? DateTime.now().toUtc().add(ttl)
        : DateTime.fromMillisecondsSinceEpoch(
            (expiresAtSeconds * 1000).round(),
            isUtc: true,
          );
    final inviteLink = Uri(
      scheme: 'readarc',
      host: 'pair',
      queryParameters: {
        'v': '2',
        'mode': settings.endpointMode.name,
        'relay': settings.effectiveRelayUrl,
        'code': code,
        'accountId': manifest.accountId,
        'ownerDeviceId': manifest.deviceId,
        'deviceName': manifest.deviceName,
        'ownerDevicePublicKey': manifest.deviceSigningPublicKey,
        'key': manifest.accountEncryptionKey,
        'expiresAt': expiresAt.toIso8601String(),
      },
    ).toString();
    _appendLog('Создан pairing-код ${code.substring(0, 3)}-${code.substring(3)}');
    return PairingInvite(
      code: code,
      relayUrl: settings.effectiveRelayUrl,
      expiresAt: expiresAt,
      inviteLink: inviteLink,
      ownerDeviceName: manifest.deviceName,
      accountEncryptionKey: manifest.accountEncryptionKey,
    );
  }

  Future<PairingClaimResult> claimPairingInvite({
    required String input,
    required SyncSettings fallbackSettings,
  }) async {
    final parsed = _parsePairingInput(input);
    final effectiveSettings = _settingsForClaimedRelayUrl(
      parsed.relayUrl ?? fallbackSettings.effectiveRelayUrl,
      fallbackSettings,
    );
    _validateEndpointForPairing(effectiveSettings);
    final relayUrl = effectiveSettings.effectiveRelayUrl;

    final local = await _storage.loadManifest();
    final uri = _buildEndpointUri(relayUrl, '/pairing/claim');
    Map<String, dynamic>? response;
    Object? claimError;
    try {
      response = await _postJson(uri, {
        'code': parsed.code,
        'deviceId': local.deviceId,
        'deviceName': local.deviceName,
        'devicePublicKey': local.deviceSigningPublicKey,
      });
      if (response['ok'] != true) {
        throw StateError(response['message']?.toString() ?? 'Pairing-код не принят relay');
      }
    } catch (error) {
      claimError = error;
      if (!parsed.hasEmbeddedAccountInvite || parsed.embeddedInviteExpired) {
        rethrow;
      }
      // QR-v2 carries the full encrypted account invite. This keeps pairing
      // working when the relay was restarted, a Tailscale/Funnel endpoint was
      // corrected between creating and scanning the code, or a mobile client
      // accidentally tries an older relay first. Manual 6-digit codes still use
      // the relay as a one-time gate.
      _appendLog('Relay не принял короткий код, используем полное QR-приглашение: $error');
    }

    final accountId = response?['accountId']?.toString() ?? parsed.accountId ?? '';
    final ownerDeviceId = response?['ownerDeviceId']?.toString() ?? parsed.ownerDeviceId ?? '';
    final ownerDeviceName = response?['ownerDeviceName']?.toString() ?? parsed.ownerDeviceName ?? 'Устройство';
    final ownerDevicePublicKey = response?['ownerDevicePublicKey']?.toString() ?? parsed.ownerDevicePublicKey ?? '';
    final accountEncryptionKey = parsed.accountEncryptionKey ?? response?['accountEncryptionKey']?.toString() ?? '';
    final returnedRelayUrl = relayUrl;
    if (accountId.isEmpty || ownerDeviceId.isEmpty) {
      throw StateError('Relay вернул неполные pairing-данные${claimError == null ? '' : ': $claimError'}');
    }
    if (accountEncryptionKey.isEmpty) {
      throw StateError('В приглашении нет ключа шифрования аккаунта');
    }

    await disconnect(manual: false);
    await _storage.saveSyncSettings(
      _settingsForClaimedRelayUrl(returnedRelayUrl, fallbackSettings).copyWith(autoConnect: true),
    );
    await _storage.replaceAccountFromPairing(
      accountId: accountId,
      accountEncryptionKey: accountEncryptionKey,
      ownerDeviceId: ownerDeviceId,
      ownerDeviceName: ownerDeviceName,
      ownerDevicePublicKey: ownerDevicePublicKey,
    );
    _appendLog('Pairing выполнен. Аккаунт подключён автоматически.');
    await connect(relayUrl: relayUrl);
    await refreshMetadata(reason: 'pairing_completed');
    return PairingClaimResult(
      accountId: accountId,
      relayUrl: relayUrl,
      ownerDeviceId: ownerDeviceId,
      ownerDeviceName: ownerDeviceName,
      accountEncryptionKey: accountEncryptionKey,
    );
  }

  void _validateEndpointForPairing(SyncSettings settings) {
    if (settings.usesOfficialPlaceholder) {
      throw StateError('Официальный relay ReadArc не настроен в этой сборке.');
    }
  }

  Uri _buildEndpointUri(String relayUrl, String endpointPath) {
    final base = Uri.parse(relayUrl.trim());
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    final cleanEndpoint = endpointPath.startsWith('/') ? endpointPath : '/$endpointPath';
    return base.replace(
      scheme: base.scheme == 'ws'
          ? 'http'
          : base.scheme == 'wss'
              ? 'https'
              : base.scheme,
      path: '$basePath$cleanEndpoint'.replaceAll(RegExp(r'/{2,}'), '/'),
      query: '',
    );
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 12));
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = responseBody.isEmpty ? <String, dynamic>{} : jsonDecode(responseBody);
      if (decoded is! Map) {
        throw StateError('Relay вернул не JSON-объект');
      }
      final result = Map<String, dynamic>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(result['message']?.toString() ?? 'HTTP ${response.statusCode}');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }

  _ParsedPairingInput _parsePairingInput(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw ArgumentError('Введите pairing-код или приглашение');
    }
    if (raw.startsWith('readarc://') || raw.startsWith('readanywhere://')) {
      final uri = Uri.parse(raw);
      final code = _normalizePairingCode(uri.queryParameters['code'] ?? '');
      final relay = uri.queryParameters['relay']?.trim();
      final accountKey = uri.queryParameters['key']?.trim();
      final ownerDeviceName = uri.queryParameters['deviceName']?.trim();
      final ownerDevicePublicKey = uri.queryParameters['ownerDevicePublicKey']?.trim();
      final accountId = uri.queryParameters['accountId']?.trim();
      final ownerDeviceId = uri.queryParameters['ownerDeviceId']?.trim();
      final expiresAtRaw = uri.queryParameters['expiresAt']?.trim();
      final expiresAt = expiresAtRaw == null || expiresAtRaw.isEmpty ? null : DateTime.tryParse(expiresAtRaw)?.toUtc();
      if (code.length != 6) {
        throw ArgumentError('В приглашении нет корректного 6-значного кода');
      }
      return _ParsedPairingInput(
        code: code,
        relayUrl: relay?.isEmpty == true ? null : relay,
        accountEncryptionKey: accountKey?.isEmpty == true ? null : accountKey,
        ownerDeviceName: ownerDeviceName?.isEmpty == true ? null : ownerDeviceName,
        ownerDevicePublicKey: ownerDevicePublicKey?.isEmpty == true ? null : ownerDevicePublicKey,
        accountId: accountId?.isEmpty == true ? null : accountId,
        ownerDeviceId: ownerDeviceId?.isEmpty == true ? null : ownerDeviceId,
        expiresAt: expiresAt,
      );
    }
    final code = _normalizePairingCode(raw);
    if (code.length != 6) {
      throw ArgumentError('Pairing-код должен состоять из 6 цифр');
    }
    return _ParsedPairingInput(code: code);
  }

  String _normalizePairingCode(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

  SyncSettings _settingsForClaimedRelayUrl(String _relayUrl, SyncSettings fallback) {
    // Sprint 25: all client connections use the official ReadArc relay.
    // Older QR links may still carry a custom/Tailscale relay parameter; keep
    // accepting the link but ignore that endpoint for the actual connection.
    return fallback.asOfficial(autoConnect: true);
  }

  Future<bool> requestBookFile(BookRecord book) async {
    final client = _client;
    if (client == null || !state.value.connected) {
      _appendLog('Нельзя скачать ${book.title}: нет подключения к relay');
      return false;
    }
    if (book.isDeleted) {
      _appendLog('${book.title} удалена из библиотеки');
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

    // Requests can be lost exactly while a mobile client or Tailscale Funnel is
    // reconnecting. Send the same idempotent request a few times until an offer
    // is received, then fail with a clear reason instead of hanging silently.
    Future<bool> sendRequest({String? label}) => _sendEnvelope(
          SyncEnvelope(
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
              'binaryTransfer': true,
            },
          ),
          logLabel: label,
        );

    for (final delay in const [Duration(seconds: 5), Duration(seconds: 12)]) {
      unawaited(Future<void>.delayed(delay, () async {
        final current = _downloadsByTransferId[transferId];
        if (current == null || current.sourceDeviceId != null) return;
        _setDownloadSnapshot(
          state.value.downloadForBook(current.bookId)!.copyWith(
                statusText: 'Повторяем поиск источника...',
                active: true,
              ),
        );
        await sendRequest();
      }));
    }

    unawaited(Future<void>.delayed(const Duration(seconds: 30), () async {
      final current = _downloadsByTransferId[transferId];
      if (current == null) return;
      if (current.sourceDeviceId == null) {
        await _failDownload(current, 'Источник не найден: устройство с книгой не ответило');
      }
    }));

    return sendRequest(label: 'Запрошен файл: ${book.title}');
  }

  Future<void> cancelBookFileDownload(String bookId) async {
    _DownloadSession? session;
    for (final candidate in _downloadsByTransferId.values) {
      if (candidate.bookId == bookId) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;
    final manifest = await _storage.loadManifest();
    final sourceDeviceId = session.sourceDeviceId;
    _downloadsByTransferId.remove(session.transferId);
    await _deletePartial(session);
    _setDownloadSnapshot(
      FileTransferSnapshot(
        transferId: session.transferId,
        bookId: session.bookId,
        direction: 'download',
        fileName: session.fileName,
        peerDeviceId: sourceDeviceId ?? '',
        statusText: 'Скачивание отменено',
        active: false,
        progressPercent: 0,
        totalBytes: session.expectedBytes,
      ),
    );
    if (sourceDeviceId != null) {
      await _sendEnvelope(
        SyncEnvelope(
          type: 'book_file_cancelled',
          accountId: manifest.accountId,
          deviceId: manifest.deviceId,
          payload: {
            'transferId': session.transferId,
            'bookId': session.bookId,
            'sourceDeviceId': sourceDeviceId,
            'requestingDeviceId': manifest.deviceId,
          },
        ),
      );
    }
    _appendLog('Скачивание отменено: ${session.fileName}');
  }

  Future<void> _handleIncomingEnvelope(SyncEnvelope envelope) async {
    var handled = false;
    try {
      await _handleIncomingEnvelopeUnsafe(envelope);
      handled = true;
    } catch (error, stackTrace) {
      // A malformed file-transfer event must never break metadata sync.
      debugPrint('Sync event handling failed: $error\n$stackTrace');
      _appendLog('Ошибка обработки ${envelope.type}: $error');
    } finally {
      if (handled) {
        _ackRelayQueueEnvelope(envelope);
      }
    }
  }

  void _ackRelayQueueEnvelope(SyncEnvelope envelope) {
    final cursor = envelope.relayQueueSeq;
    final client = _client;
    if (cursor == null || client == null || !state.value.connected) return;
    try {
      client.sendControl({
        'type': 'offline_queue_ack',
        'accountId': envelope.accountId,
        'deviceId': client.deviceId,
        'payload': {
          'cursor': cursor,
        },
      });
    } catch (error) {
      _appendLog('Не удалось подтвердить offline queue: $error');
    }
  }

  Future<void> _handleIncomingEnvelopeUnsafe(SyncEnvelope envelope) async {
    final local = await _storage.loadManifest();
    if (envelope.accountId != local.accountId) {
      _appendLog('Пропущено событие другого аккаунта: ${envelope.accountId}');
      return;
    }
    if (envelope.deviceId == local.deviceId) return;

    if (envelope.type == 'peer_list') {
      final peers = ((envelope.payload['peers'] as List?) ?? const [])
          .map((item) => item.toString())
          .where((id) => id != local.deviceId)
          .toList();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Relay peers online: ${peers.length}');
      await refreshMetadata(reason: 'peer_list');
      return;
    }

    if (envelope.type == 'peer_joined') {
      final peers = {...state.value.onlinePeerDeviceIds, envelope.deviceId}.toList()..sort();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Подключилось другое устройство: ${envelope.deviceId}');
      await refreshMetadata(reason: 'peer_joined');
      return;
    }

    if (envelope.type == 'peer_left') {
      final peers = state.value.onlinePeerDeviceIds
          .where((id) => id != envelope.deviceId)
          .toList()
        ..sort();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Отключилось другое устройство: ${envelope.deviceId}');
      return;
    }

    if (envelope.type == 'pairing_claimed') {
      await _handlePairingClaimed(envelope, local);
      return;
    }

    if (envelope.type == 'error') {
      _appendLog('Relay вернул ошибку: ${envelope.payload['message'] ?? envelope.payload}');
      return;
    }

    if (_isRevokedDevice(local, envelope.deviceId)) {
      _appendLog('Отклонено событие от отозванного устройства: ${envelope.deviceId}');
      return;
    }

    if (!_acceptSecureEnvelope(envelope)) {
      return;
    }

    final decryptedPayload = await ReadAnywhereE2eCrypto.decryptPayload(
      encryptedPayload: envelope.payload,
      accountEncryptionKey: local.accountEncryptionKey,
      eventType: envelope.type,
      accountId: envelope.accountId,
      deviceId: envelope.deviceId,
      createdAt: envelope.createdAt,
    );
    final decryptedEnvelope = SyncEnvelope(
      type: envelope.type,
      accountId: envelope.accountId,
      deviceId: envelope.deviceId,
      createdAt: envelope.createdAt,
      payload: decryptedPayload,
    );

    if (!_acceptTrustedDevicePayload(local, decryptedEnvelope)) {
      return;
    }

    switch (decryptedEnvelope.type) {
      case 'library_snapshot_requested':
        await _handleLibrarySnapshotRequested(decryptedEnvelope, local);
        break;
      case 'library_snapshot':
        await _handleLibrarySnapshot(decryptedEnvelope, local);
        break;
      case 'book_file_requested':
        await _handleBookFileRequested(decryptedEnvelope, local);
        break;
      case 'book_file_offer':
        await _handleBookFileOffer(decryptedEnvelope, local);
        break;
      case 'book_file_accept':
        unawaited(_handleBookFileAccept(decryptedEnvelope, local));
        break;
      case 'book_file_chunk':
        await _handleBookFileChunk(decryptedEnvelope, local);
        break;
      case 'book_file_chunk_ack':
        await _handleBookFileChunkAck(decryptedEnvelope, local);
        break;
      case 'book_file_error':
        await _handleBookFileError(decryptedEnvelope, local);
        break;
      case 'book_file_cancelled':
        await _handleBookFileCancelled(decryptedEnvelope, local);
        break;
      default:
        _appendLog('Неизвестное событие: ${decryptedEnvelope.type}');
    }
  }

  bool _acceptSecureEnvelope(SyncEnvelope envelope) {
    final eventId = ReadAnywhereE2eCrypto.encryptedEventId(envelope.payload);
    if (eventId == null || eventId.isEmpty) {
      // Legacy encrypted payload from older test builds. Accept during rollout.
      return true;
    }
    final issuedAt = ReadAnywhereE2eCrypto.encryptedIssuedAt(envelope.payload);
    final now = DateTime.now().toUtc();
    if (issuedAt == null) {
      _appendLog('Отклонено событие без issuedAt: ${envelope.type}');
      return false;
    }
    if (issuedAt.isBefore(now.subtract(_replayWindow)) || issuedAt.isAfter(now.add(const Duration(minutes: 5)))) {
      _appendLog('Отклонено устаревшее/будущее событие: ${envelope.type}');
      return false;
    }
    _seenSecureEventIds.removeWhere((_, seenAt) => seenAt.isBefore(now.subtract(_replayWindow)));
    final replayKey = '${envelope.accountId}:${envelope.deviceId}:$eventId';
    if (_seenSecureEventIds.containsKey(replayKey)) {
      _appendLog('Отклонён повтор события: ${envelope.type}');
      return false;
    }
    _seenSecureEventIds[replayKey] = now;
    return true;
  }

  bool _isRevokedDevice(LibraryManifest local, String deviceId) {
    for (final device in local.trustedDevices) {
      if (device.deviceId == deviceId) return device.isRevoked;
    }
    return false;
  }

  bool _isActiveTrustedDevice(LibraryManifest local, String deviceId) {
    for (final device in local.trustedDevices) {
      if (device.deviceId == deviceId) return !device.isRevoked;
    }
    return false;
  }

  bool _acceptTrustedDevicePayload(LibraryManifest local, SyncEnvelope envelope) {
    if (_isActiveTrustedDevice(local, envelope.deviceId)) return true;

    // First event from a freshly paired device can be its library snapshot. It is
    // already encrypted with the account key from the one-time QR invite. Accept
    // only if the snapshot explicitly introduces the sender as a trusted device
    // with a public key; all other unknown-device events are rejected.
    if (envelope.type == 'library_snapshot') {
      final payloadManifest = envelope.payload['manifest'];
      if (payloadManifest is Map) {
        final devices = (payloadManifest['trustedDevices'] as List?) ?? const [];
        for (final item in devices.whereType<Map>()) {
          final candidate = TrustedDeviceRecord.fromJson(Map<String, dynamic>.from(item));
          if (candidate.deviceId == envelope.deviceId && !candidate.isRevoked && candidate.hasPublicKey) {
            _appendLog('Принято первое доверенное событие от ${candidate.name}');
            return true;
          }
        }
      }
    }

    _appendLog('Отклонено событие от недоверенного устройства: ${envelope.deviceId}');
    return false;
  }

  Future<void> _handlePairingClaimed(SyncEnvelope envelope, LibraryManifest local) async {
    if (envelope.deviceId != 'relay') return;
    final ownerDeviceId = envelope.payload['ownerDeviceId']?.toString() ?? '';
    if (ownerDeviceId.isNotEmpty && ownerDeviceId != local.deviceId) return;

    final acceptedDeviceId = envelope.payload['acceptedDeviceId']?.toString().trim() ?? '';
    if (acceptedDeviceId.isEmpty || acceptedDeviceId == local.deviceId) return;

    final acceptedDeviceName = envelope.payload['acceptedDeviceName']?.toString().trim() ?? 'Устройство';
    final acceptedDevicePublicKey = envelope.payload['acceptedDevicePublicKey']?.toString().trim() ?? '';

    final updated = await _storage.trustDevice(
      deviceId: acceptedDeviceId,
      name: acceptedDeviceName.isEmpty ? 'Устройство' : acceptedDeviceName,
      role: 'device',
      publicKey: acceptedDevicePublicKey,
    );
    _manifestChanges.add(updated);
    _appendLog('Устройство снова доверено через QR: $acceptedDeviceName');
    await broadcastLibrarySnapshot(reason: 'pairing_claimed_reauthorized_device');
  }

  Future<void> _handleLibrarySnapshotRequested(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final requester = envelope.payload['requestingDeviceId'] as String?;
    if (requester == local.deviceId) return;
    _appendLog('Получен запрос snapshot от ${envelope.deviceId}');
    await broadcastLibrarySnapshot(reason: 'requested_by_peer');
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
    if (merged.isCurrentDeviceRevoked) {
      _appendLog('Доступ этого устройства отозван. Синхронизация остановлена.');
      await disconnect(manual: true);
      _setState(state.value.copyWith(
        connected: false,
        statusText: 'Доступ этого устройства отозван',
      ));
      return;
    }
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
    final directUrls = await _createDirectShareUrls(book: book, file: file);

    if (directUrls.isEmpty) {
      _appendLog('Direct/LAN endpoint недоступен для ${book.title}; будет использован relay fallback');
    } else {
      _appendLog('Direct/LAN URLs для ${book.title}: ${directUrls.length}');
    }

    await _sendEnvelope(
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
          'binaryTransfer': true,
          'directDownloadUrls': directUrls,
          'directTransfer': directUrls.isNotEmpty,
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
    final tempFile = File(p.join(incomingDir.path, '${session.bookId}.part'));
    if (!await tempFile.exists()) await tempFile.create(recursive: true);

    final chunkSize = (payload['chunkSize'] as num?)?.toInt() ?? _defaultChunkSize;
    var resumeBytes = await tempFile.length();
    if (resumeBytes > session.expectedBytes) {
      await tempFile.writeAsBytes(const [], flush: true);
      resumeBytes = 0;
    }
    final alignedResumeBytes = chunkSize <= 0 ? 0 : (resumeBytes ~/ chunkSize) * chunkSize;
    if (alignedResumeBytes != resumeBytes) {
      final raf = await tempFile.open(mode: FileMode.writeOnlyAppend);
      try {
        await raf.truncate(alignedResumeBytes);
      } finally {
        await raf.close();
      }
      resumeBytes = alignedResumeBytes;
    }

    session
      ..sourceDeviceId = sourceDeviceId
      ..tempFile = tempFile
      ..chunkSize = chunkSize
      ..receivedBytes = resumeBytes
      ..expectedChunkIndex = chunkSize <= 0 ? 0 : resumeBytes ~/ chunkSize;

    final resumeText = resumeBytes > 0
        ? 'Продолжаем с ${_formatBytes(resumeBytes)}...'
        : 'Источник найден, начинаем скачивание...';
    _setDownloadSnapshot(
      state.value.downloadForBook(session.bookId)!.copyWith(
            statusText: resumeText,
            peerDeviceId: sourceDeviceId,
            transferredBytes: resumeBytes,
            progressPercent: session.expectedBytes <= 0 ? 0 : (resumeBytes / session.expectedBytes) * 100,
            active: true,
            clearError: true,
          ),
    );

    final directUrls = ((payload['directDownloadUrls'] as List?) ?? const [])
        .map((item) => item.toString())
        .where((url) => url.trim().isNotEmpty)
        .toList();
    if (directUrls.isNotEmpty) {
      final directOk = await _tryDirectDownload(session, directUrls);
      if (directOk) return;
      final existing = state.value.downloadForBook(session.bookId);
      if (existing != null) {
        _setDownloadSnapshot(existing.copyWith(
          statusText: 'Direct/LAN недоступен, используем relay...',
          active: true,
          clearError: true,
        ));
      }
    }

    await _sendEnvelope(
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
          'startChunkIndex': session.expectedChunkIndex,
          'binaryTransfer': true,
        },
      ),
    );
    _resetDownloadWatchdog(session);
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
        startChunkIndex: (payload['startChunkIndex'] as num?)?.toInt() ?? 0,
        binaryTransfer: payload['binaryTransfer'] == true,
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
    required int startChunkIndex,
    required bool binaryTransfer,
  }) async {
    final book = _findBook(await _storage.loadManifest(), bookId);
    if (book == null || book.localPath == null) {
      await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Файл не найден у источника');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Локальный файл отсутствует');
      return;
    }

    final size = await file.length();
    final safeChunkSize = chunkSize.clamp(256 * 1024, _defaultChunkSize).toInt();
    final totalChunks = (size / safeChunkSize).ceil();
    final safeStartChunkIndex = startChunkIndex.clamp(0, totalChunks).toInt();
    final startOffset = (safeStartChunkIndex * safeChunkSize).clamp(0, size).toInt();
    final uploadKey = 'upload:$transferId';
    _cancelledTransfers.remove(transferId);

    _updateTransferByKey(
      uploadKey,
      FileTransferSnapshot(
        transferId: transferId,
        bookId: bookId,
        direction: 'upload',
        fileName: book.fileName,
        peerDeviceId: requestingDeviceId,
        statusText: startOffset > 0 ? 'Возобновляем отправку...' : 'Отправка файла...',
        active: true,
        transferredBytes: startOffset,
        progressPercent: size == 0 ? 100 : (startOffset / size) * 100,
        totalBytes: size,
      ),
    );

    final raf = await file.open(mode: FileMode.read);
    await raf.setPosition(startOffset);
    var chunkIndex = safeStartChunkIndex;
    var sentBytes = startOffset;
    var failed = false;
    final transferStartedAt = DateTime.now();
    try {
      while (true) {
        if (_cancelledTransfers.contains(transferId)) {
          _appendLog('Отправка отменена получателем: ${book.title}');
          break;
        }
        final data = await raf.read(safeChunkSize);
        if (data.isEmpty) break;
        sentBytes += data.length;
        var acknowledged = false;
        for (var attempt = 1; attempt <= 3 && !acknowledged; attempt++) {
          final ackKey = _ackKey(transferId, chunkIndex);
          final ackCompleter = Completer<void>();
          _uploadAckWaiters[ackKey] = ackCompleter;
          final sent = binaryTransfer
              ? await _sendBinaryFileChunk(
                  local: local,
                  transferId: transferId,
                  bookId: bookId,
                  requestingDeviceId: requestingDeviceId,
                  chunkIndex: chunkIndex,
                  totalChunks: totalChunks,
                  offset: chunkIndex * safeChunkSize,
                  totalBytes: size,
                  sha256Text: book.contentSha256,
                  data: data,
                )
              : await _sendEnvelope(
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
          if (!sent) {
            _uploadAckWaiters.remove(ackKey);
            if (attempt == 3) {
              failed = true;
              await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Не удалось отправить chunk $chunkIndex');
              break;
            }
            continue;
          }
          try {
            await ackCompleter.future.timeout(const Duration(seconds: 20));
            acknowledged = true;
          } on TimeoutException {
            _uploadAckWaiters.remove(ackKey);
            if (attempt < 3) {
              _updateTransferByKey(
                uploadKey,
                state.value.fileTransfers[uploadKey]!.copyWith(
                      statusText: 'Повтор chunk $chunkIndex ($attempt/3)...',
                    ),
              );
              await Future<void>.delayed(const Duration(milliseconds: 350));
            } else {
              failed = true;
              await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Получатель не подтвердил chunk $chunkIndex');
            }
          }
        }
        if (!acknowledged) break;
        final progress = size == 0 ? 100.0 : (sentBytes / size) * 100;
        final elapsed = DateTime.now().difference(transferStartedAt).inMilliseconds.clamp(1, 1 << 31);
        final mbps = ((sentBytes - startOffset) / (1024 * 1024)) / (elapsed / 1000.0);
        _updateTransferByKey(
          uploadKey,
          state.value.fileTransfers[uploadKey]!.copyWith(
                progressPercent: progress.clamp(0, 100).toDouble(),
                transferredBytes: sentBytes,
                statusText: 'Отправка: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              ),
        );
        chunkIndex += 1;
        if (chunkIndex % 4 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      final wasCancelled = _cancelledTransfers.remove(transferId);
      final existingTransfer = state.value.fileTransfers[uploadKey]!;
      _updateTransferByKey(
        uploadKey,
        existingTransfer.copyWith(
              progressPercent: (wasCancelled || failed) ? existingTransfer.progressPercent : 100,
              transferredBytes: (wasCancelled || failed) ? existingTransfer.transferredBytes : size,
              statusText: wasCancelled
                  ? 'Отправка отменена'
                  : failed
                      ? 'Отправка прервана'
                      : 'Файл отправлен',
              active: false,
            ),
      );
      if (!wasCancelled && !failed) {
        _appendLog('Файл отправлен: ${book.title}');
      }
    } catch (error) {
      _updateTransferByKey(
        uploadKey,
        state.value.fileTransfers[uploadKey]!.copyWith(
              statusText: 'Ошибка отправки',
              active: false,
              error: '$error',
            ),
      );
      await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Ошибка отправки: $error');
    } finally {
      await raf.close();
    }
  }


  Future<bool> _sendBinaryFileChunk({
    required LibraryManifest local,
    required String transferId,
    required String bookId,
    required String requestingDeviceId,
    required int chunkIndex,
    required int totalChunks,
    required int offset,
    required int totalBytes,
    required String sha256Text,
    required List<int> data,
  }) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;
    try {
      final encrypted = await ReadAnywhereE2eCrypto.encryptBinaryFrame(
        accountEncryptionKey: local.accountEncryptionKey,
        clearBytes: data,
        headerFields: {
          'frame': 'readanywhere-binary-v1',
          'type': 'book_file_binary_chunk',
          'accountId': local.accountId,
          'deviceId': local.deviceId,
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'chunkIndex': chunkIndex,
          'totalChunks': totalChunks,
          'offset': offset,
          'totalBytes': totalBytes,
          'sha256': sha256Text,
        },
      );
      client.sendBinary(RelayBinaryMessage(header: encrypted.header, body: encrypted.cipherBytes));
      _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
      return true;
    } catch (error) {
      _appendLog('Не удалось отправить binary chunk $chunkIndex: $error');
      unawaited(_handleRelayDisconnected(error));
      return false;
    }
  }

  Future<void> _handleIncomingBinaryFrame(RelayBinaryMessage message) async {
    try {
      final local = await _storage.loadManifest();
      final header = message.header;
      if (header['type'] != 'book_file_binary_chunk') return;
      if (header['accountId'] != local.accountId) return;
      if (header['requestingDeviceId'] != local.deviceId) return;
      final sourceDeviceId = header['sourceDeviceId']?.toString() ?? header['deviceId']?.toString() ?? '';
      if (_isRevokedDevice(local, sourceDeviceId) || !_isActiveTrustedDevice(local, sourceDeviceId)) {
        _appendLog('Отклонён binary chunk от недоверенного/отозванного устройства: $sourceDeviceId');
        return;
      }
      final clearBytes = await ReadAnywhereE2eCrypto.decryptBinaryFrame(
        header: header,
        cipherBytes: message.body,
        accountEncryptionKey: local.accountEncryptionKey,
      );
      await _handleBookFileBinaryChunk(header, clearBytes, local);
    } catch (error, stackTrace) {
      debugPrint('Binary sync event handling failed: $error\n$stackTrace');
      _appendLog('Ошибка binary transfer: $error');
    }
  }

  Future<void> _handleBookFileBinaryChunk(
    Map<String, dynamic> payload,
    List<int> data,
    LibraryManifest local,
  ) async {
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    if (session.sourceDeviceId != null && payload['sourceDeviceId'] != session.sourceDeviceId) return;

    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (chunkIndex == null) return;
    if (chunkIndex != session.expectedChunkIndex) {
      // Duplicate chunks can arrive when the source retries after a delayed ACK.
      // ACK them again and keep the already written file intact.
      if (chunkIndex < session.expectedChunkIndex) {
        await _sendChunkAck(local, session, chunkIndex);
        return;
      }
      await _failDownload(
        session,
        'Нарушен порядок binary chunks: ожидали ${session.expectedChunkIndex}, получили $chunkIndex',
      );
      return;
    }

    final tempFile = session.tempFile;
    if (tempFile == null) return;
    try {
      await tempFile.writeAsBytes(data, mode: FileMode.append, flush: false);
      session
        ..expectedChunkIndex += 1
        ..receivedBytes += data.length
        ..totalChunks = (payload['totalChunks'] as num?)?.toInt()
        ..expectedBytes = (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes;

      final totalBytes = session.expectedBytes;
      final progress = totalBytes <= 0 ? 0.0 : (session.receivedBytes / totalBytes) * 100;
      final elapsed = DateTime.now().difference(session.startedAt).inMilliseconds.clamp(1, 1 << 31);
      final mbps = (session.receivedBytes / (1024 * 1024)) / (elapsed / 1000.0);
      _setDownloadSnapshot(
        state.value.downloadForBook(session.bookId)!.copyWith(
              statusText: 'Скачивание: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: totalBytes,
              active: true,
            ),
      );

      _resetDownloadWatchdog(session);
      await _sendChunkAck(local, session, chunkIndex);

      final totalChunks = session.totalChunks;
      if (totalChunks != null && session.expectedChunkIndex >= totalChunks) {
        session.watchdog?.cancel();
        await _finalizeDownload(session);
      }
    } catch (error) {
      await _failDownload(session, 'Ошибка получения binary chunk: $error');
    }
  }

  Future<void> _sendChunkAck(LibraryManifest local, _DownloadSession session, int chunkIndex) async {
    await _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_chunk_ack',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': session.transferId,
          'bookId': session.bookId,
          'sourceDeviceId': session.sourceDeviceId,
          'requestingDeviceId': local.deviceId,
          'chunkIndex': chunkIndex,
          'receivedBytes': session.receivedBytes,
        },
      ),
    );
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
      final elapsed = DateTime.now().difference(session.startedAt).inMilliseconds.clamp(1, 1 << 31);
      final mbps = (session.receivedBytes / (1024 * 1024)) / (elapsed / 1000.0);
      _setDownloadSnapshot(
        state.value.downloadForBook(session.bookId)!.copyWith(
              statusText: 'Скачивание: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: totalBytes,
              active: true,
            ),
      );

      _resetDownloadWatchdog(session);
      await _sendChunkAck(local, session, chunkIndex);

      final totalChunks = session.totalChunks;
      if (totalChunks != null && session.expectedChunkIndex >= totalChunks) {
        session.watchdog?.cancel();
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
        deletePartial: true,
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

    _clearTransferForBook(session.bookId);
    _appendLog('Файл скачан: ${session.fileName}');
    await broadcastLibrarySnapshot(reason: 'book_file_downloaded');
  }


  Future<void> _handleBookFileChunkAck(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (transferId == null || chunkIndex == null) return;
    final completer = _uploadAckWaiters.remove(_ackKey(transferId, chunkIndex));
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  String _ackKey(String transferId, int chunkIndex) => '$transferId:$chunkIndex';

  void _resetDownloadWatchdog(_DownloadSession session) {
    session.watchdog?.cancel();
    session.watchdog = Timer(const Duration(seconds: 90), () {
      final current = _downloadsByTransferId[session.transferId];
      if (current == null || current.sourceDeviceId == null) return;
      unawaited(_failDownload(current, 'Источник перестал отвечать во время скачивания'));
    });
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

  Future<void> _failDownload(
    _DownloadSession session,
    String message, {
    bool deletePartial = false,
  }) async {
    session.watchdog?.cancel();
    if (deletePartial) {
      await _deletePartial(session);
    }
    _downloadsByTransferId.remove(session.transferId);
    final existing = state.value.downloadForBook(session.bookId);
    if (existing != null) {
      _setDownloadSnapshot(
        existing.copyWith(
          statusText: deletePartial
              ? 'Ошибка скачивания'
              : 'Пауза/ошибка. Нажмите скачать ещё раз — продолжим, если возможно.',
          active: false,
          error: message,
        ),
      );
    }
    _appendLog('Ошибка скачивания ${session.fileName}: $message');
  }

  Future<void> _handleBookFileCancelled(
    SyncEnvelope envelope,
    LibraryManifest local,
  ) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    _cancelledTransfers.add(transferId);
    final uploadKey = 'upload:$transferId';
    final existing = state.value.fileTransfers[uploadKey];
    if (existing != null) {
      _updateTransferByKey(
        uploadKey,
        existing.copyWith(
          statusText: 'Получатель отменил скачивание',
          active: false,
        ),
      );
    }
  }

  Future<void> _deletePartial(_DownloadSession session) async {
    try {
      final tempFile = session.tempFile;
      if (tempFile != null && await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      // Best effort cleanup.
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }


  Future<void> _ensureDirectFileServer() async {
    if (_directFileServer != null) return;
    for (final port in const [8790, 8791, 0]) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
        _directFileServer = server;
        _directFileServerPort = server.port;
        server.listen(
          (request) => unawaited(_handleDirectFileRequest(request)),
          onError: (Object error) => debugPrint('Direct file server error: $error'),
          cancelOnError: false,
        );
        _appendLog('Direct/LAN file endpoint: port ${server.port}');
        return;
      } catch (_) {
        if (port == 0) rethrow;
      }
    }
  }

  Future<List<String>> _createDirectShareUrls({required BookRecord book, required File file}) async {
    try {
      await _ensureDirectFileServer();
      final port = _directFileServerPort;
      if (port == null) return const [];
      final token = _uuid.v4().replaceAll('-', '');
      _directShares[token] = _DirectFileShare(
        token: token,
        bookId: book.id,
        file: file,
        fileName: book.fileName,
        sha256: book.contentSha256,
        sizeBytes: await file.length(),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );
      _directShares.removeWhere((_, share) => share.expiresAt.isBefore(DateTime.now().toUtc()));
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final urls = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address;
          if (host.startsWith('169.254.')) continue;
          urls.add('http://$host:$port/direct-file/$token');
        }
      }
      return urls.toSet().toList()..sort();
    } catch (error) {
      debugPrint('Cannot create Direct/LAN share: $error');
      return const [];
    }
  }

  Future<void> _handleDirectFileRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      final isDownloadMethod = request.method == 'GET' || request.method == 'HEAD';
      if (!isDownloadMethod || segments.length != 2 || segments[0] != 'direct-file') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final token = segments[1];
      final share = _directShares[token];
      if (share == null || share.expiresAt.isBefore(DateTime.now().toUtc()) || !await share.file.exists()) {
        _directShares.remove(token);
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final size = await share.file.length();
      var start = 0;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
        if (match != null) start = int.tryParse(match.group(1) ?? '0') ?? 0;
      }
      start = start.clamp(0, size).toInt();
      request.response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
        ..set('X-ReadAnywhere-Book-Id', share.bookId)
        ..set('X-ReadAnywhere-Sha256', share.sha256)
        ..set('X-ReadAnywhere-File-Name', Uri.encodeComponent(share.fileName));
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${size - 1}/$size');
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      request.response.contentLength = size - start;
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        await share.file.openRead(start).pipe(request.response);
      }
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      debugPrint('Direct file request failed: $error');
    }
  }

  List<Uri> _directDownloadCandidates(List<String> urls) {
    final seen = <String>{};
    final candidates = <Uri>[];
    for (final rawUrl in urls) {
      final uri = Uri.tryParse(rawUrl.trim());
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) continue;
      if (!seen.add(uri.toString())) continue;
      candidates.add(uri);
    }
    candidates.sort((a, b) => _directHostRank(a.host).compareTo(_directHostRank(b.host)));
    return candidates;
  }

  int _directHostRank(String host) {
    if (host.startsWith('192.168.') || host.startsWith('10.') || host.startsWith('172.16.') || host.startsWith('172.17.') || host.startsWith('172.18.') || host.startsWith('172.19.') || host.startsWith('172.2') || host.startsWith('172.30.') || host.startsWith('172.31.')) {
      return 0;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length == 4 && parts[0] == 100 && parts[1] != null && parts[1]! >= 64 && parts[1]! <= 127) {
      return 1; // Tailscale/CGNAT range: still usually fast, but after ordinary LAN.
    }
    return 2;
  }

  Future<Uri?> _selectReachableDirectUrl(List<Uri> candidates, String bookId) async {
    if (candidates.isEmpty) return null;
    final snap = state.value.downloadForBook(bookId);
    if (snap != null) {
      _setDownloadSnapshot(snap.copyWith(
        statusText: 'Быстро проверяем Direct/LAN (${candidates.length})...',
        active: true,
        clearError: true,
      ));
    }

    final probing = candidates.take(12).toList(growable: false);
    final completer = Completer<Uri?>();
    var pending = probing.length;
    for (final uri in probing) {
      unawaited(_probeDirectUrl(uri).then((ok) {
        if (ok && !completer.isCompleted) completer.complete(uri);
      }).whenComplete(() {
        pending -= 1;
        if (pending <= 0 && !completer.isCompleted) completer.complete(null);
      }));
    }
    return completer.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
  }

  Future<bool> _probeDirectUrl(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 900);
    try {
      final request = await client.openUrl('HEAD', uri).timeout(const Duration(milliseconds: 1200));
      final response = await request.close().timeout(const Duration(milliseconds: 1500));
      final ok = response.statusCode == HttpStatus.ok || response.statusCode == HttpStatus.partialContent;
      try {
        await response.drain().timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      } catch (_) {}
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _tryDirectDownload(_DownloadSession session, List<String> urls) async {
    final tempFile = session.tempFile;
    if (tempFile == null) return false;
    session.watchdog?.cancel();
    final candidates = _directDownloadCandidates(urls);
    final selected = await _selectReachableDirectUrl(candidates, session.bookId);
    if (selected == null) {
      _resetDownloadWatchdog(session);
      return false;
    }

    final ordered = <Uri>[
      selected,
      ...candidates.where((candidate) => candidate != selected),
    ];
    for (final uri in ordered.take(3)) {
      final ok = await _downloadFromDirectUri(session, uri, tempFile);
      if (ok) return true;
    }
    _resetDownloadWatchdog(session);
    return false;
  }

  Future<bool> _downloadFromDirectUri(_DownloadSession session, Uri uri, File tempFile) async {
    final existing = state.value.downloadForBook(session.bookId);
    if (existing != null) {
      _setDownloadSnapshot(existing.copyWith(
        statusText: 'Direct/LAN: соединяемся...',
        active: true,
        clearError: true,
      ));
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    IOSink? sink;
    try {
      var resumeBytes = await tempFile.exists() ? await tempFile.length() : 0;
      if (resumeBytes > session.expectedBytes) {
        await tempFile.writeAsBytes(const [], flush: true);
        resumeBytes = 0;
      }
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      if (resumeBytes > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeBytes-');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        await response.drain();
        return false;
      }
      if (response.statusCode == HttpStatus.ok && resumeBytes > 0) {
        await tempFile.writeAsBytes(const [], flush: true);
        resumeBytes = 0;
      }
      session.receivedBytes = resumeBytes;
      sink = tempFile.openWrite(mode: FileMode.append);
      final startedAt = DateTime.now();
      var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in response.timeout(const Duration(seconds: 120))) {
        sink.add(chunk);
        session.receivedBytes += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds > 250) {
          lastUi = now;
          final progress = session.expectedBytes <= 0 ? 0.0 : (session.receivedBytes / session.expectedBytes) * 100;
          final elapsed = now.difference(startedAt).inMilliseconds.clamp(1, 1 << 31);
          final mbps = ((session.receivedBytes - resumeBytes) / (1024 * 1024)) / (elapsed / 1000.0);
          final snap = state.value.downloadForBook(session.bookId);
          if (snap != null) {
            _setDownloadSnapshot(snap.copyWith(
              statusText: 'Direct/LAN: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: session.expectedBytes,
              active: true,
            ));
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (session.expectedBytes <= 0 || session.receivedBytes >= session.expectedBytes) {
        final snap = state.value.downloadForBook(session.bookId);
        if (snap != null) {
          _setDownloadSnapshot(snap.copyWith(statusText: 'Проверяем SHA-256...', active: true));
        }
        await _finalizeDownload(session);
        return true;
      }
      return false;
    } catch (error) {
      debugPrint('Direct/LAN download failed from $uri: $error');
      return false;
    } finally {
      try { await sink?.close(); } catch (_) {}
      client.close(force: true);
    }
  }


  Future<void> _sendFileError(
    LibraryManifest local,
    String transferId,
    String bookId,
    String requestingDeviceId,
    String message,
  ) async {
    await _sendEnvelope(
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
      if (book.id == bookId && !book.isDeleted) return book;
    }
    return null;
  }

  Future<bool> _sendEnvelope(SyncEnvelope envelope, {String? logLabel}) async {
    final client = _client;
    if (client == null || !state.value.connected) {
      _appendLog('Не отправлено ${envelope.type}: нет подключения к relay');
      return false;
    }
    try {
      final local = await _storage.loadManifest();
      if (local.isCurrentDeviceRevoked) {
        _appendLog('Не отправлено ${envelope.type}: доступ этого устройства отозван');
        await disconnect(manual: true);
        _setState(state.value.copyWith(
          connected: false,
          statusText: 'Доступ этого устройства отозван',
        ));
        return false;
      }
      final encryptedPayload = await ReadAnywhereE2eCrypto.encryptPayload(
        payload: envelope.payload,
        accountEncryptionKey: local.accountEncryptionKey,
        eventType: envelope.type,
        accountId: envelope.accountId,
        deviceId: envelope.deviceId,
        createdAt: envelope.createdAt,
      );
      client.send(SyncEnvelope(
        type: envelope.type,
        accountId: envelope.accountId,
        deviceId: envelope.deviceId,
        createdAt: envelope.createdAt,
        payload: encryptedPayload,
      ));
      if (logLabel != null && logLabel.isNotEmpty) {
        _appendLog(logLabel);
      }
      _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
      return true;
    } catch (error) {
      _appendLog('Не удалось отправить ${envelope.type}: $error');
      unawaited(_handleRelayDisconnected(error));
      return false;
    }
  }

  void _setDownloadSnapshot(FileTransferSnapshot snapshot) {
    _updateTransferByKey(snapshot.bookId, snapshot);
  }

  void _updateTransferByKey(String key, FileTransferSnapshot snapshot) {
    final updated = Map<String, FileTransferSnapshot>.from(state.value.fileTransfers);
    updated[key] = snapshot;
    _setState(state.value.copyWith(fileTransfers: Map.unmodifiable(updated)));
  }

  void _clearTransferForBook(String bookId) {
    final updated = Map<String, FileTransferSnapshot>.from(state.value.fileTransfers);
    updated.remove(bookId);
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
    await disconnect(manual: true);
    _reconnectTimer?.cancel();
    await _directFileServer?.close(force: true);
    _directFileServer = null;
    _directShares.clear();
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
  Timer? watchdog;
  final DateTime startedAt = DateTime.now();
}


class _DirectFileShare {
  const _DirectFileShare({
    required this.token,
    required this.bookId,
    required this.file,
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    required this.expiresAt,
  });

  final String token;
  final String bookId;
  final File file;
  final String fileName;
  final String sha256;
  final int sizeBytes;
  final DateTime expiresAt;
}
