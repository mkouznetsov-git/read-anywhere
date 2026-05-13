import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/sync_settings.dart';

void main() {
  test('defaults to official ReadArc relay with autoconnect', () {
    const settings = SyncSettings();

    expect(settings.endpointMode, RelayEndpointMode.official);
    expect(settings.effectiveRelayUrl, ReadArcRelayConfig.officialRelayUrl);
    expect(settings.effectiveRelayUrl, 'https://relay.readarc.ru');
    expect(settings.autoConnect, isTrue);
  });

  test('migrates legacy custom relayUrl to official relay', () {
    final settings = SyncSettings.fromJson({
      'relayUrl': 'https://old-personal-hub.tailnet.ts.net',
      'autoConnect': false,
    });

    expect(settings.endpointMode, RelayEndpointMode.official);
    expect(settings.effectiveRelayUrl, ReadArcRelayConfig.officialRelayUrl);
    expect(settings.autoConnect, isTrue);
  });

  test('copyWith keeps official relay while preserving explicit autoconnect flag', () {
    const settings = SyncSettings(
      endpointMode: RelayEndpointMode.custom,
      customRelayUrl: 'http://127.0.0.1:8787',
      autoConnect: false,
    );

    final copied = settings.copyWith(
      endpointMode: RelayEndpointMode.personalHub,
      personalHubRelayUrl: 'https://my-mac.tailnet.ts.net',
    );

    expect(copied.endpointMode, RelayEndpointMode.official);
    expect(copied.effectiveRelayUrl, ReadArcRelayConfig.officialRelayUrl);
    expect(copied.autoConnect, isFalse);
  });

  test('toJson stores only official relay fields', () {
    const settings = SyncSettings();
    final json = settings.toJson();

    expect(json['endpointMode'], 'official');
    expect(json['relayUrl'], ReadArcRelayConfig.officialRelayUrl);
    expect(json['customRelayUrl'], ReadArcRelayConfig.officialRelayUrl);
    expect(json['personalHubRelayUrl'], ReadArcRelayConfig.officialRelayUrl);
    expect(json['autoConnect'], isTrue);
  });
}
