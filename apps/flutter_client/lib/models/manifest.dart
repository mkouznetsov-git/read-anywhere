import 'book.dart';

class TrustedDeviceRecord {
  TrustedDeviceRecord({
    required this.deviceId,
    required this.name,
    this.role = 'device',
    DateTime? addedAt,
    DateTime? lastSeenAt,
    this.deletedAt,
  })  : addedAt = addedAt ?? DateTime.now().toUtc(),
        lastSeenAt = lastSeenAt ?? DateTime.now().toUtc();

  final String deviceId;
  final String name;
  final String role;
  final DateTime addedAt;
  final DateTime lastSeenAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  TrustedDeviceRecord copyWith({
    String? deviceId,
    String? name,
    String? role,
    DateTime? addedAt,
    DateTime? lastSeenAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return TrustedDeviceRecord(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      role: role ?? this.role,
      addedAt: addedAt ?? this.addedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'role': role,
        'addedAt': addedAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
        'deletedAt': deletedAt?.toIso8601String(),
      };

  factory TrustedDeviceRecord.fromJson(Map<String, dynamic> json) => TrustedDeviceRecord(
        deviceId: json['deviceId'] as String? ?? 'unknown-device',
        name: json['name'] as String? ?? 'Устройство',
        role: json['role'] as String? ?? 'device',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        deletedAt: json['deletedAt'] == null
            ? null
            : DateTime.tryParse(json['deletedAt'] as String),
      );
}

class LibraryManifest {
  LibraryManifest({
    required this.accountId,
    required this.deviceId,
    this.deviceName = 'Моё устройство',
    DateTime? updatedAt,
    List<BookRecord>? books,
    List<TrustedDeviceRecord>? trustedDevices,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        books = books ?? [],
        trustedDevices = trustedDevices ?? [];

  final String accountId;
  final String deviceId;
  final String deviceName;
  final DateTime updatedAt;
  final List<BookRecord> books;
  final List<TrustedDeviceRecord> trustedDevices;

  List<BookRecord> get visibleBooks => sortBooksForLibrary(books);
  List<TrustedDeviceRecord> get activeTrustedDevices => trustedDevices
      .where((device) => !device.isDeleted)
      .toList()
    ..sort((a, b) {
      final ownerCompare = (b.role == 'owner' ? 1 : 0).compareTo(a.role == 'owner' ? 1 : 0);
      if (ownerCompare != 0) return ownerCompare;
      final currentCompare = (b.deviceId == deviceId ? 1 : 0).compareTo(a.deviceId == deviceId ? 1 : 0);
      if (currentCompare != 0) return currentCompare;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  LibraryManifest copyWith({
    String? accountId,
    String? deviceId,
    String? deviceName,
    DateTime? updatedAt,
    List<BookRecord>? books,
    List<TrustedDeviceRecord>? trustedDevices,
  }) {
    return LibraryManifest(
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      books: books ?? this.books,
      trustedDevices: trustedDevices ?? this.trustedDevices,
    );
  }

  Map<String, dynamic> toJson() => _toJson(includeLocalPaths: true);

  /// Portable snapshot for other devices. It includes book metadata and the
  /// availability map but strips local filesystem paths.
  Map<String, dynamic> toSyncJson() => _toJson(includeLocalPaths: false);

  Map<String, dynamic> _toJson({required bool includeLocalPaths}) => {
        'accountId': accountId,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'updatedAt': updatedAt.toIso8601String(),
        'trustedDevices': trustedDevices.map((d) => d.toJson()).toList(),
        'books': books
            .map((b) => b.toJson(includeLocalPath: includeLocalPaths))
            .toList(),
      };

  factory LibraryManifest.fromJson(Map<String, dynamic> json) => LibraryManifest(
        accountId: json['accountId'] as String? ?? 'local-account',
        deviceId: json['deviceId'] as String? ?? 'local-device',
        deviceName: json['deviceName'] as String? ?? 'Моё устройство',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        trustedDevices: ((json['trustedDevices'] as List?) ?? [])
            .whereType<Map>()
            .map((item) => TrustedDeviceRecord.fromJson(Map<String, dynamic>.from(item)))
            .toList(),
        books: ((json['books'] as List?) ?? [])
            .map((item) => BookRecord.fromJson(item as Map<String, dynamic>))
            .toList(),
      );
}

class SyncEnvelope {
  SyncEnvelope({
    required this.type,
    required this.accountId,
    required this.deviceId,
    required this.payload,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String type;
  final String accountId;
  final String deviceId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'type': type,
        'accountId': accountId,
        'deviceId': deviceId,
        'createdAt': createdAt.toIso8601String(),
        'payload': payload,
      };

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) => SyncEnvelope(
        type: json['type'] as String,
        accountId: json['accountId'] as String,
        deviceId: json['deviceId'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );
}
