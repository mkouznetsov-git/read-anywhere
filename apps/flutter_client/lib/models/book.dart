import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum BookDownloadStatus { downloaded, remoteOnly, missingLocalFile }

class BookmarkRecord {
  BookmarkRecord({
    String? id,
    required this.bookId,
    required this.label,
    required this.locator,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String bookId;
  final String label;
  final String locator;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  BookmarkRecord copyWith({
    String? label,
    String? locator,
    String? note,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return BookmarkRecord(
      id: id,
      bookId: bookId,
      label: label ?? this.label,
      locator: locator ?? this.locator,
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'label': label,
        'locator': locator,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'deletedAt': deletedAt?.toIso8601String(),
      };

  factory BookmarkRecord.fromJson(Map<String, dynamic> json) => BookmarkRecord(
        id: json['id'] as String,
        bookId: json['bookId'] as String,
        label: json['label'] as String? ?? 'Закладка',
        locator: json['locator'] as String? ?? '',
        note: json['note'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        deletedAt: json['deletedAt'] == null
            ? null
            : DateTime.tryParse(json['deletedAt'] as String),
      );
}

class BookRecord {
  BookRecord({
    required this.id,
    required this.title,
    required this.fileName,
    required this.format,
    required this.sizeBytes,
    required this.contentSha256,
    this.localPath,
    DateTime? addedAt,
    DateTime? updatedAt,
    this.progressPercent = 0,
    this.currentLocator = '',
    this.progressVersion = 0,
    this.updatedByDeviceId = 'local-device',
    List<String>? availableOnDeviceIds,
    List<BookmarkRecord>? bookmarks,
  })  : addedAt = addedAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc(),
        availableOnDeviceIds = _uniqueStrings(availableOnDeviceIds ?? const []),
        bookmarks = bookmarks ?? [];

  final String id;
  final String title;
  final String fileName;
  final String format;
  final int sizeBytes;
  final String contentSha256;

  /// Path is intentionally local-only. It must never be trusted from another
  /// device. Remote snapshots carry [availableOnDeviceIds] instead.
  final String? localPath;

  final DateTime addedAt;
  final DateTime updatedAt;
  final double progressPercent;
  final String currentLocator;
  final int progressVersion;
  final String updatedByDeviceId;
  final List<String> availableOnDeviceIds;
  final List<BookmarkRecord> bookmarks;

  bool get isDownloaded => localPath != null && localPath!.isNotEmpty;

  BookDownloadStatus get downloadStatus =>
      isDownloaded ? BookDownloadStatus.downloaded : BookDownloadStatus.remoteOnly;

  bool isAvailableOnDevice(String deviceId) => availableOnDeviceIds.contains(deviceId);

  BookRecord copyWith({
    String? title,
    String? fileName,
    String? format,
    int? sizeBytes,
    String? contentSha256,
    String? localPath,
    DateTime? updatedAt,
    double? progressPercent,
    String? currentLocator,
    int? progressVersion,
    String? updatedByDeviceId,
    List<String>? availableOnDeviceIds,
    List<BookmarkRecord>? bookmarks,
  }) {
    return BookRecord(
      id: id,
      title: title ?? this.title,
      fileName: fileName ?? this.fileName,
      format: format ?? this.format,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      contentSha256: contentSha256 ?? this.contentSha256,
      localPath: localPath ?? this.localPath,
      addedAt: addedAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      progressPercent: progressPercent ?? this.progressPercent,
      currentLocator: currentLocator ?? this.currentLocator,
      progressVersion: progressVersion ?? this.progressVersion,
      updatedByDeviceId: updatedByDeviceId ?? this.updatedByDeviceId,
      availableOnDeviceIds: availableOnDeviceIds ?? this.availableOnDeviceIds,
      bookmarks: bookmarks ?? this.bookmarks,
    );
  }

  Map<String, dynamic> toJson({bool includeLocalPath = true}) => {
        'id': id,
        'title': title,
        'fileName': fileName,
        'format': format,
        'sizeBytes': sizeBytes,
        'contentSha256': contentSha256,
        'localPath': includeLocalPath ? localPath : null,
        'addedAt': addedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'progressPercent': progressPercent,
        'currentLocator': currentLocator,
        'progressVersion': progressVersion,
        'updatedByDeviceId': updatedByDeviceId,
        'availableOnDeviceIds': availableOnDeviceIds,
        'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
      };

  factory BookRecord.fromJson(Map<String, dynamic> json) => BookRecord(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'Без названия',
        fileName: json['fileName'] as String? ?? '',
        format: json['format'] as String? ?? 'unknown',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        contentSha256: json['contentSha256'] as String? ?? json['id'] as String,
        localPath: json['localPath'] as String?,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0,
        currentLocator: json['currentLocator'] as String? ?? '',
        progressVersion: (json['progressVersion'] as num?)?.toInt() ?? 0,
        updatedByDeviceId: json['updatedByDeviceId'] as String? ?? 'unknown',
        availableOnDeviceIds: ((json['availableOnDeviceIds'] as List?) ?? [])
            .map((item) => item.toString())
            .toList(),
        bookmarks: ((json['bookmarks'] as List?) ?? [])
            .map((item) => BookmarkRecord.fromJson(item as Map<String, dynamic>))
            .toList(),
      );
}

List<String> _uniqueStrings(List<String> items) {
  return items.where((item) => item.trim().isNotEmpty).toSet().toList()..sort();
}
