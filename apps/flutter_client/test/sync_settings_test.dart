import 'package:flutter_test/flutter_test.dart';
import 'package:read_anywhere/models/sync_settings.dart';

void main() {
  test('migrates legacy relayUrl settings to custom mode', () {
    final settings = SyncSettings.fromJson({
      'relayUrl': 'https://relay.example.test',
      'autoConnect': true,
    });

    expect(settings.endpointMode, RelayEndpointMode.custom);
    expect(settings.customRelayUrl, 'https://relay.example.test');
    expect(settings.effectiveRelayUrl, 'https://relay.example.test');
    expect(settings.autoConnect, isTrue);
  });

  test('detects local development legacy relayUrl', () {
    final settings = SyncSettings.fromJson({
      'relayUrl': 'http://127.0.0.1:8787',
    });

    expect(settings.endpointMode, RelayEndpointMode.localDevelopment);
    expect(settings.effectiveRelayUrl, ReadAnywhereRelayConfig.localDevelopmentRelayUrl);
  });

  test('official mode uses compile-time default relay URL', () {
    const settings = SyncSettings(endpointMode: RelayEndpointMode.official);

    expect(settings.effectiveRelayUrl, ReadAnywhereRelayConfig.officialRelayUrl);
  });
}
