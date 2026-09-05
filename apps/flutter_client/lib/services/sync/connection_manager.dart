import 'dart:io';

import '../../models/manifest.dart';
import 'relay_client.dart';

/// Owns relay endpoint probing, client construction and retry policy.
class ConnectionManager {
  const ConnectionManager();

  RelayClient createClient({required Uri relayUri, required LibraryManifest manifest}) =>
      RelayClient(relayUri: relayUri, accountId: manifest.accountId, deviceId: manifest.deviceId);

  int retryDelaySeconds(int attempt) {
    const delays = [2, 2, 5, 5, 5, 5];
    return delays[attempt.clamp(0, delays.length - 1).toInt()];
  }

  Future<void> probeHealth(String relayUrl, {required Duration timeout}) async {
    final uri = endpointUri(relayUrl, '/health');
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

  Uri endpointUri(String relayUrl, String endpointPath) {
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
}
