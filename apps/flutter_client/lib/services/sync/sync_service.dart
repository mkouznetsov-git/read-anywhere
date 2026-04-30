import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/manifest.dart';
import '../../models/sync_settings.dart';
import '../storage_service.dart';
import 'merge.dart';
import 'relay_client.dart';

class SyncStateSnapshot {
  const SyncStateSnapshot({
    required this.connected,
    required this.statusText,
    this.relayUrl,
    this.sentEvents = 0,
    this.receivedEvents = 0,
    this.logLines = const [],
  });

  final bool connected;
  final String statusText;
  final String? relayUrl;
  final int sentEvents;
  final int receivedEvents;
  final List<String> logLines;

  SyncStateSnapshot copyWith({
    bool? connected,
    String? statusText,
    String? relayUrl,
    int? sentEvents,
    int? receivedEvents,
    List<String>? logLines,
  }) {
    return SyncStateSnapshot(
      connected: connected ?? this.connected,
      statusText: statusText ?? this.statusText,
      relayUrl: relayUrl ?? this.relayUrl,
      sentEvents: sentEvents ?? this.sentEvents,
      receivedEvents: receivedEvents ?? this.receivedEvents,
      logLines: logLines ?? this.logLines,
    );
  }
}

class SyncService {
  SyncService(this._storage);

  final StorageService _storage;
  final state = ValueNotifier<SyncStateSnapshot>(
    const SyncStateSnapshot(connected: false, statusText: 'Не подключено'),
  );

  RelayClient? _client;
  StreamSubscription<SyncEnvelope>? _incomingSubscription;
  final _manifestChanges = StreamController<LibraryManifest>.broadcast();

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
    _incomingSubscription = client.incoming.listen(
      _handleIncomingEnvelope,
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

    if (envelope.type != 'library_snapshot') {
      _appendLog('Неизвестное событие: ${envelope.type}');
      return;
    }

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
