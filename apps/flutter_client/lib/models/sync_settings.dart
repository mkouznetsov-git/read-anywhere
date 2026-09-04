/// ReadArc sync endpoint configuration.
///
/// Starting with Sprint 25 the app no longer exposes relay endpoint choices in
/// the UI. All normal builds use the official ReadArc relay. The old enum and
/// JSON fields are intentionally kept for migration/backwards compatibility:
/// older settings files, older QR links and older tests can still be decoded,
/// but the effective endpoint is always the official relay.
enum RelayEndpointMode { official, custom, personalHub, localDevelopment }

class ReadArcRelayConfig {
  const ReadArcRelayConfig._();

  /// Production ReadArc relay.
  ///
  /// Can still be overridden by CI/dev builds, but defaults to our deployed
  /// public server instead of an example placeholder.
  static const officialRelayUrl = String.fromEnvironment(
    'READARC_DEFAULT_RELAY_URL',
    defaultValue: 'https://relay.readarc.ru',
  );

  static const localDevelopmentRelayUrl = 'http://127.0.0.1:8787';
  static const personalHubPlaceholderUrl = 'https://your-device.your-tailnet.ts.net';

  static bool get officialRelayLooksConfigured =>
      officialRelayUrl.trim().isNotEmpty && !officialRelayUrl.contains('example.com');
}

class SyncSettings {
  const SyncSettings({
    this.endpointMode = RelayEndpointMode.official,
    this.customRelayUrl = ReadArcRelayConfig.officialRelayUrl,
    this.personalHubRelayUrl = ReadArcRelayConfig.officialRelayUrl,
    this.autoConnect = true,
  });

  /// Retained only to decode old settings. The app-facing endpoint is always
  /// [ReadArcRelayConfig.officialRelayUrl].
  final RelayEndpointMode endpointMode;
  final String customRelayUrl;
  final String personalHubRelayUrl;
  final bool autoConnect;

  /// Backwards-compatible name used by older code and docs.
  String get relayUrl => effectiveRelayUrl;

  String get effectiveRelayUrl => ReadArcRelayConfig.officialRelayUrl;

  bool get usesOfficialPlaceholder => !ReadArcRelayConfig.officialRelayLooksConfigured;

  bool get usesPersonalHubPlaceholder => false;

  SyncSettings asOfficial({bool? autoConnect}) => SyncSettings(
    endpointMode: RelayEndpointMode.official,
    customRelayUrl: ReadArcRelayConfig.officialRelayUrl,
    personalHubRelayUrl: ReadArcRelayConfig.officialRelayUrl,
    autoConnect: autoConnect ?? this.autoConnect,
  );

  SyncSettings copyWith({
    RelayEndpointMode? endpointMode,
    String? customRelayUrl,
    String? personalHubRelayUrl,
    bool? autoConnect,
  }) => SyncSettings(
    endpointMode: RelayEndpointMode.official,
    customRelayUrl: ReadArcRelayConfig.officialRelayUrl,
    personalHubRelayUrl: ReadArcRelayConfig.officialRelayUrl,
    autoConnect: autoConnect ?? this.autoConnect,
  );

  Map<String, dynamic> toJson() => {
    'endpointMode': RelayEndpointMode.official.name,
    'customRelayUrl': ReadArcRelayConfig.officialRelayUrl,
    'personalHubRelayUrl': ReadArcRelayConfig.officialRelayUrl,
    'autoConnect': true,
    'relayUrl': ReadArcRelayConfig.officialRelayUrl,
  };

  factory SyncSettings.fromJson(Map<String, dynamic> json) {
    // Old builds could store custom/local/personal-hub endpoints. From Sprint
    // 25 we migrate them all to the official ReadArc relay and enable
    // autoconnect so users never have to pick connection mode manually.
    return const SyncSettings(
      endpointMode: RelayEndpointMode.official,
      customRelayUrl: ReadArcRelayConfig.officialRelayUrl,
      personalHubRelayUrl: ReadArcRelayConfig.officialRelayUrl,
      autoConnect: true,
    );
  }

  static RelayEndpointMode? parseEndpointModeForLegacyDiagnostics(String? raw) {
    if (raw == null) return null;
    for (final value in RelayEndpointMode.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}
