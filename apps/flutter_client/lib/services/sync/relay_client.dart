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
    _subscription = channel.stream.listen(
      _handleRawMessage,
      onError: _incoming.addError,
      onDone: () {
        if (!_incoming.isClosed) {
          _incoming.addError(StateError('Relay connection closed'));
        }
      },
      cancelOnError: false,
    );
  }

  void _handleRawMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decodedRaw = jsonDecode(raw);
      if (decodedRaw is! Map) {
        _incoming.add(_systemError('Relay message is not an object'));
        return;
      }
      final decoded = Map<String, dynamic>.from(decodedRaw);
      final type = decoded['type'] as String?;
      if (type == 'peer_joined' || type == 'peer_left' || type == 'peer_list' || type == 'error') {
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
      if (type == null || decoded['payload'] is! Map) {
        _incoming.add(_systemError('Relay message has invalid sync envelope'));
        return;
      }
      _incoming.add(SyncEnvelope.fromJson(decoded));
    } catch (error) {
      _incoming.add(_systemError('Cannot parse relay message: $error'));
    }
  }

  SyncEnvelope _systemError(String message) => SyncEnvelope(
        type: 'error',
        accountId: accountId,
        deviceId: 'relay-client',
        payload: {'message': message},
      );

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
