class SyncSettings {
  const SyncSettings({
    this.relayUrl = 'http://127.0.0.1:8787',
    this.autoConnect = false,
  });

  final String relayUrl;
  final bool autoConnect;

  SyncSettings copyWith({String? relayUrl, bool? autoConnect}) => SyncSettings(
        relayUrl: relayUrl ?? this.relayUrl,
        autoConnect: autoConnect ?? this.autoConnect,
      );

  Map<String, dynamic> toJson() => {
        'relayUrl': relayUrl,
        'autoConnect': autoConnect,
      };

  factory SyncSettings.fromJson(Map<String, dynamic> json) => SyncSettings(
        relayUrl: json['relayUrl'] as String? ?? 'http://127.0.0.1:8787',
        autoConnect: json['autoConnect'] as bool? ?? false,
      );
}
