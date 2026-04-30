import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/manifest.dart';

class RelayClient {
  RelayClient({
    required this.relayUri,
    required this.accountId,
    required this.deviceId,
  });

  final Uri relayUri;
  final String accountId;
  final String deviceId;

  WebSocketChannel? _channel;
  final _incoming = StreamController<SyncEnvelope>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  Stream<SyncEnvelope> get incoming => _incoming.stream;

  Future<void> connect() async {
    final scheme = relayUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = relayUri.replace(
      scheme: scheme,
      path: '/ws/$accountId/$deviceId',
      query: '',
    );
    final channel = WebSocketChannel.connect(wsUri);
    _channel = channel;
    _subscription = channel.stream.listen((raw) {
      if (raw is! String) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final type = decoded['type'] as String?;
      if (type == 'peer_joined' || type == 'peer_left' || type == 'error') {
        _incoming.add(
          SyncEnvelope(
            type: type ?? 'relay_system',
            accountId: decoded['accountId'] as String? ?? accountId,
            deviceId: decoded['deviceId'] as String? ?? 'relay',
            payload: decoded,
          ),
        );
        return;
      }
      _incoming.add(SyncEnvelope.fromJson(decoded));
    }, onError: _incoming.addError, onDone: () {
      _incoming.addError(StateError('Relay connection closed'));
    });
  }

  void send(SyncEnvelope envelope) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('RelayClient is not connected');
    }
    channel.sink.add(jsonEncode(envelope.toJson()));
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await close();
    await _incoming.close();
  }
}
