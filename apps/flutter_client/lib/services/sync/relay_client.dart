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

  Stream<SyncEnvelope> get incoming => _incoming.stream;

  Future<void> connect() async {
    final wsUri = relayUri.replace(
      scheme: relayUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/$accountId/$deviceId',
    );
    _channel = WebSocketChannel.connect(wsUri);
    _channel!.stream.listen((raw) {
      final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = decoded['type'] as String?;
      if (type == 'peer_joined' || type == 'peer_left') return;
      _incoming.add(SyncEnvelope.fromJson(decoded));
    }, onError: _incoming.addError);
  }

  void send(SyncEnvelope envelope) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('RelayClient is not connected');
    }
    channel.sink.add(jsonEncode(envelope.toJson()));
  }

  Future<void> close() async {
    await _channel?.sink.close();
    await _incoming.close();
  }
}
