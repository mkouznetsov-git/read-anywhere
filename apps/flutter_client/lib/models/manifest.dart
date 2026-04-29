import 'book.dart';

class LibraryManifest {
  LibraryManifest({
    required this.accountId,
    required this.deviceId,
    DateTime? updatedAt,
    List<BookRecord>? books,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        books = books ?? [];

  final String accountId;
  final String deviceId;
  final DateTime updatedAt;
  final List<BookRecord> books;

  LibraryManifest copyWith({
    String? accountId,
    String? deviceId,
    DateTime? updatedAt,
    List<BookRecord>? books,
  }) {
    return LibraryManifest(
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      books: books ?? this.books,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'deviceId': deviceId,
        'updatedAt': updatedAt.toIso8601String(),
        'books': books.map((b) => b.toJson()).toList(),
      };

  factory LibraryManifest.fromJson(Map<String, dynamic> json) => LibraryManifest(
        accountId: json['accountId'] as String? ?? 'local-account',
        deviceId: json['deviceId'] as String? ?? 'local-device',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
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
        createdAt: DateTime.parse(json['createdAt'] as String),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );
}
