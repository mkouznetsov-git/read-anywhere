enum RelayEndpointMode {
  official,
  custom,
  localDevelopment,
}

class ReadAnywhereRelayConfig {
  const ReadAnywhereRelayConfig._();

  /// Compile-time default for product builds.
  ///
  /// Override during builds with:
  ///   flutter build ... --dart-define=READANYWHERE_DEFAULT_RELAY_URL=https://your-relay.example.com
  static const officialRelayUrl = String.fromEnvironment(
    'READANYWHERE_DEFAULT_RELAY_URL',
    defaultValue: 'https://readanywhere-relay.example.com',
  );

  static const localDevelopmentRelayUrl = 'http://127.0.0.1:8787';

  static bool get officialRelayLooksConfigured =>
      !officialRelayUrl.contains('example.com');
}

class SyncSettings {
  const SyncSettings({
    this.endpointMode = RelayEndpointMode.custom,
    this.customRelayUrl = ReadAnywhereRelayConfig.localDevelopmentRelayUrl,
    this.autoConnect = false,
  });

  final RelayEndpointMode endpointMode;
  final String customRelayUrl;
  final bool autoConnect;

  /// Backwards-compatible name used by older code and docs.
  String get relayUrl => effectiveRelayUrl;

  String get effectiveRelayUrl {
    switch (endpointMode) {
      case RelayEndpointMode.official:
        return ReadAnywhereRelayConfig.officialRelayUrl;
      case RelayEndpointMode.localDevelopment:
        return ReadAnywhereRelayConfig.localDevelopmentRelayUrl;
      case RelayEndpointMode.custom:
        final normalized = customRelayUrl.trim();
        return normalized.isEmpty
            ? ReadAnywhereRelayConfig.localDevelopmentRelayUrl
            : normalized;
    }
  }

  bool get usesOfficialPlaceholder =>
      endpointMode == RelayEndpointMode.official &&
      !ReadAnywhereRelayConfig.officialRelayLooksConfigured;

  SyncSettings copyWith({
    RelayEndpointMode? endpointMode,
    String? customRelayUrl,
    bool? autoConnect,
  }) =>
      SyncSettings(
        endpointMode: endpointMode ?? this.endpointMode,
        customRelayUrl: customRelayUrl ?? this.customRelayUrl,
        autoConnect: autoConnect ?? this.autoConnect,
      );

  Map<String, dynamic> toJson() => {
        'endpointMode': endpointMode.name,
        'customRelayUrl': customRelayUrl,
        'autoConnect': autoConnect,
        // Keep a resolved field for easy manual debugging and migration.
        'relayUrl': effectiveRelayUrl,
      };

  factory SyncSettings.fromJson(Map<String, dynamic> json) {
    final mode = _parseEndpointMode(json['endpointMode'] as String?);
    final custom = json['customRelayUrl'] as String?;
    final legacyRelayUrl = json['relayUrl'] as String?;

    // Migration path from Sprint 2/3 settings that had only relayUrl.
    if (mode == null) {
      final legacy = (legacyRelayUrl ?? ReadAnywhereRelayConfig.localDevelopmentRelayUrl).trim();
      final isLocal = legacy == ReadAnywhereRelayConfig.localDevelopmentRelayUrl ||
          legacy.contains('127.0.0.1') ||
          legacy.contains('localhost');
      return SyncSettings(
        endpointMode: isLocal ? RelayEndpointMode.localDevelopment : RelayEndpointMode.custom,
        customRelayUrl: legacy.isEmpty ? ReadAnywhereRelayConfig.localDevelopmentRelayUrl : legacy,
        autoConnect: json['autoConnect'] as bool? ?? false,
      );
    }

    return SyncSettings(
      endpointMode: mode,
      customRelayUrl: custom ??
          legacyRelayUrl ??
          ReadAnywhereRelayConfig.localDevelopmentRelayUrl,
      autoConnect: json['autoConnect'] as bool? ?? false,
    );
  }

  static RelayEndpointMode? _parseEndpointMode(String? raw) {
    if (raw == null) return null;
    for (final value in RelayEndpointMode.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}
