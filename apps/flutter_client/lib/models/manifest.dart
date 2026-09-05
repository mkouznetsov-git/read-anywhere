import 'book.dart';

import 'package:uuid/uuid.dart';

const _syncUuid = Uuid();

class TrustedDeviceRecord {
  TrustedDeviceRecord({
    required this.deviceId,
    required this.name,
    this.role = 'device',
    this.publicKey = '',
    this.keyFingerprint = '',
    this.canSyncMetadata = true,
    this.canTransferFiles = true,
    DateTime? addedAt,
    DateTime? lastSeenAt,
    this.deletedAt,
    this.revokedByDeviceId,
    this.revokedReason,
  }) : addedAt = addedAt ?? DateTime.now().toUtc(),
       lastSeenAt = lastSeenAt ?? DateTime.now().toUtc();

  final String deviceId;
  final String name;
  final String role;
  final String publicKey;
  final String keyFingerprint;
  final bool canSyncMetadata;
  final bool canTransferFiles;
  final DateTime addedAt;
  final DateTime lastSeenAt;

  /// Backward compatible tombstone field. In ReadArc Sprint 26 it means that
  /// device access is revoked, not merely hidden in the UI.
  final DateTime? deletedAt;
  final String? revokedByDeviceId;
  final String? revokedReason;

  bool get isDeleted => deletedAt != null;
  bool get isRevoked => deletedAt != null;
  bool get isOwner => role == 'owner';
  bool get hasPublicKey => publicKey.trim().isNotEmpty;

  String get trustStatusLabel => isRevoked ? 'Доступ отозван' : 'Доверенное';

  String get effectiveFingerprint {
    final explicit = keyFingerprint.trim();
    if (explicit.isNotEmpty) return explicit;
    final key = publicKey.trim();
    if (key.length >= 16) return '${key.substring(0, 8)}…${key.substring(key.length - 8)}';
    final id = deviceId.trim();
    if (id.length >= 16) return '${id.substring(0, 8)}…${id.substring(id.length - 8)}';
    return id;
  }

  TrustedDeviceRecord copyWith({
    String? deviceId,
    String? name,
    String? role,
    String? publicKey,
    String? keyFingerprint,
    bool? canSyncMetadata,
    bool? canTransferFiles,
    DateTime? addedAt,
    DateTime? lastSeenAt,
    DateTime? deletedAt,
    String? revokedByDeviceId,
    String? revokedReason,
    bool clearDeletedAt = false,
    bool clearRevocation = false,
  }) {
    return TrustedDeviceRecord(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      role: role ?? this.role,
      publicKey: publicKey ?? this.publicKey,
      keyFingerprint: keyFingerprint ?? this.keyFingerprint,
      canSyncMetadata: canSyncMetadata ?? this.canSyncMetadata,
      canTransferFiles: canTransferFiles ?? this.canTransferFiles,
      addedAt: addedAt ?? this.addedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      deletedAt: clearDeletedAt || clearRevocation ? null : (deletedAt ?? this.deletedAt),
      revokedByDeviceId: clearRevocation ? null : (revokedByDeviceId ?? this.revokedByDeviceId),
      revokedReason: clearRevocation ? null : (revokedReason ?? this.revokedReason),
    );
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'role': role,
    'publicKey': publicKey,
    'keyFingerprint': keyFingerprint,
    'permissions': {'syncMetadata': canSyncMetadata, 'transferFiles': canTransferFiles},
    'addedAt': addedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'revokedAt': deletedAt?.toIso8601String(),
    'revokedByDeviceId': revokedByDeviceId,
    'revokedReason': revokedReason,
  };

  factory TrustedDeviceRecord.fromJson(Map<String, dynamic> json) {
    final permissions = json['permissions'] is Map
        ? Map<String, dynamic>.from(json['permissions'] as Map)
        : const <String, dynamic>{};
    final revokedAt = json['revokedAt'] == null ? null : DateTime.tryParse(json['revokedAt'].toString());
    final deletedAt = json['deletedAt'] == null
        ? revokedAt
        : DateTime.tryParse(json['deletedAt'].toString()) ?? revokedAt;
    return TrustedDeviceRecord(
      deviceId: json['deviceId'] as String? ?? 'unknown-device',
      name: json['name'] as String? ?? 'Устройство',
      role: json['role'] as String? ?? 'device',
      publicKey: json['publicKey'] as String? ?? '',
      keyFingerprint: json['keyFingerprint'] as String? ?? '',
      canSyncMetadata: permissions['syncMetadata'] != false,
      canTransferFiles: permissions['transferFiles'] != false,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
      lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? '') ?? DateTime.now().toUtc(),
      deletedAt: deletedAt,
      revokedByDeviceId: json['revokedByDeviceId'] as String?,
      revokedReason: json['revokedReason'] as String?,
    );
  }
}

class LibraryManifest {
  static const currentSchemaVersion = 3;

  LibraryManifest({
    this.schemaVersion = currentSchemaVersion,
    required this.accountId,
    required this.deviceId,
    this.deviceName = 'Моё устройство',
    this.accountEncryptionKey = '',
    this.deviceSigningPublicKey = '',
    this.deviceSigningPrivateKey = '',
    DateTime? updatedAt,
    List<BookRecord>? books,
    List<TrustedDeviceRecord>? trustedDevices,
    this.logicalClock = 0,
    List<String>? appliedOperationIds,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc(),
       books = books ?? [],
       trustedDevices = trustedDevices ?? [],
       appliedOperationIds = appliedOperationIds ?? [];

  final String accountId;
  final int schemaVersion;
  final String deviceId;
  final String deviceName;
  final String accountEncryptionKey;
  final String deviceSigningPublicKey;
  final String deviceSigningPrivateKey;
  final DateTime updatedAt;
  final List<BookRecord> books;
  final List<TrustedDeviceRecord> trustedDevices;
  final int logicalClock;
  final List<String> appliedOperationIds;

  List<BookRecord> get visibleBooks => sortBooksForLibrary(books);

  TrustedDeviceRecord? get currentDeviceTrust {
    for (final device in trustedDevices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  bool get isCurrentDeviceRevoked => currentDeviceTrust?.isRevoked == true;
  List<TrustedDeviceRecord> get activeTrustedDevices =>
      trustedDevices.where((device) => !device.isDeleted).toList()..sort((a, b) {
        final ownerCompare = (b.role == 'owner' ? 1 : 0).compareTo(a.role == 'owner' ? 1 : 0);
        if (ownerCompare != 0) return ownerCompare;
        final currentCompare = (b.deviceId == deviceId ? 1 : 0).compareTo(a.deviceId == deviceId ? 1 : 0);
        if (currentCompare != 0) return currentCompare;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  LibraryManifest copyWith({
    int? schemaVersion,
    String? accountId,
    String? deviceId,
    String? deviceName,
    String? accountEncryptionKey,
    String? deviceSigningPublicKey,
    String? deviceSigningPrivateKey,
    DateTime? updatedAt,
    List<BookRecord>? books,
    List<TrustedDeviceRecord>? trustedDevices,
    int? logicalClock,
    List<String>? appliedOperationIds,
  }) {
    return LibraryManifest(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      accountEncryptionKey: accountEncryptionKey ?? this.accountEncryptionKey,
      deviceSigningPublicKey: deviceSigningPublicKey ?? this.deviceSigningPublicKey,
      deviceSigningPrivateKey: deviceSigningPrivateKey ?? this.deviceSigningPrivateKey,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      books: books ?? this.books,
      trustedDevices: trustedDevices ?? this.trustedDevices,
      logicalClock: logicalClock ?? this.logicalClock,
      appliedOperationIds: appliedOperationIds ?? this.appliedOperationIds,
    );
  }

  Map<String, dynamic> toJson() => _toJson(includeLocalPaths: true);

  /// Portable snapshot for other devices. It includes book metadata and the
  /// availability map but strips local filesystem paths.
  Map<String, dynamic> toSyncJson() => _toJson(includeLocalPaths: false);

  Map<String, dynamic> _toJson({required bool includeLocalPaths}) => {
    'schemaVersion': schemaVersion,
    'accountId': accountId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'deviceSigningPublicKey': deviceSigningPublicKey,
    'crypto': {'payload': 'readarc-e2e-v2'},
    'updatedAt': updatedAt.toIso8601String(),
    'trustedDevices': trustedDevices.map((d) => d.toJson()).toList(),
    'books': books.map((b) => b.toJson(includeLocalPath: includeLocalPaths)).toList(),
    'logicalClock': logicalClock,
    'appliedOperationIds': appliedOperationIds,
  };

  factory LibraryManifest.fromJson(Map<String, dynamic> json) => LibraryManifest(
    schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
    accountId: json['accountId'] as String? ?? 'local-account',
    deviceId: json['deviceId'] as String? ?? 'local-device',
    deviceName: json['deviceName'] as String? ?? 'Моё устройство',
    accountEncryptionKey: json['accountEncryptionKey'] as String? ?? '',
    deviceSigningPublicKey: json['deviceSigningPublicKey'] as String? ?? '',
    deviceSigningPrivateKey: json['deviceSigningPrivateKey'] as String? ?? '',
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    trustedDevices: ((json['trustedDevices'] as List?) ?? [])
        .whereType<Map>()
        .map((item) => TrustedDeviceRecord.fromJson(Map<String, dynamic>.from(item)))
        .toList(),
    books: ((json['books'] as List?) ?? []).map((item) => BookRecord.fromJson(item as Map<String, dynamic>)).toList(),
    logicalClock: (json['logicalClock'] as num?)?.toInt() ?? 0,
    appliedOperationIds: ((json['appliedOperationIds'] as List?) ?? const []).map((item) => item.toString()).toList(),
  );
}

class SyncEnvelope {
  static const currentProtocolVersion = 3;
  static const minimumProtocolVersion = 2;

  SyncEnvelope({
    required this.type,
    required this.accountId,
    required this.deviceId,
    required this.payload,
    DateTime? createdAt,
    this.relayQueueSeq,
    this.protocolVersion = currentProtocolVersion,
    String? operationId,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       operationId = operationId ?? _syncUuid.v4();

  final String type;
  final String accountId;
  final String deviceId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int? relayQueueSeq;
  final int protocolVersion;
  final String operationId;

  Map<String, dynamic> toJson() => {
    'type': type,
    'accountId': accountId,
    'deviceId': deviceId,
    'createdAt': createdAt.toIso8601String(),
    'payload': payload,
    if (relayQueueSeq != null) 'relayQueueSeq': relayQueueSeq,
    'protocolVersion': protocolVersion,
    'operationId': operationId,
  };

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) => SyncEnvelope(
    type: json['type'] as String,
    accountId: json['accountId'] as String,
    deviceId: json['deviceId'] as String,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    payload: Map<String, dynamic>.from(json['payload'] as Map),
    relayQueueSeq: (json['relayQueueSeq'] as num?)?.toInt(),
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? minimumProtocolVersion,
    operationId: json['operationId']?.toString() ?? 'legacy-${json['deviceId']}-${json['type']}-${json['createdAt']}',
  );
}
