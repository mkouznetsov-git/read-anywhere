import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/models/sync_revision.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/merge.dart';
import 'package:readarc/services/sync/metadata_sync_engine.dart';
import 'package:readarc/services/sync/sync_authorization.dart';

void main() {
  test('independent offline metadata, progress and bookmark revisions all survive', () {
    final base = _book(
      title: 'Original',
      metadataRevision: const SyncRevision(counter: 1, deviceId: 'a'),
      progressRevision: const SyncRevision(counter: 1, deviceId: 'a'),
    );
    final onA = base.copyWith(
      title: 'Renamed offline',
      metadataRevision: const SyncRevision(counter: 2, deviceId: 'a'),
      bookmarks: [_bookmark('bookmark-a', const SyncRevision(counter: 3, deviceId: 'a'))],
    );
    final onB = base.copyWith(
      progressPercent: 71,
      currentLocator: 'txt:71',
      progressRevision: const SyncRevision(counter: 2, deviceId: 'b'),
      bookmarks: [_bookmark('bookmark-b', const SyncRevision(counter: 3, deviceId: 'b'))],
    );

    final merged = mergeManifests(_manifest('a', onA), _manifest('b', onB));
    expect(merged.books.single.title, 'Renamed offline');
    expect(merged.books.single.progressPercent, 71);
    expect(merged.books.single.bookmarks.map((item) => item.id).toSet(), {'bookmark-a', 'bookmark-b'});
  });

  test('clock skew cannot resurrect a book deleted by a higher logical revision', () {
    final deletion = _book(
      title: 'Deleted',
      updatedAt: DateTime.utc(2000),
      deletedAt: DateTime.utc(2000),
      metadataRevision: const SyncRevision(counter: 9, deviceId: 'a'),
      tombstoneAcks: const ['a'],
    );
    final staleFutureSnapshot = _book(
      title: 'Stale active',
      updatedAt: DateTime.utc(2099),
      metadataRevision: const SyncRevision(counter: 8, deviceId: 'b'),
    );

    final merged = mergeManifests(_manifest('a', deletion), _manifest('b', staleFutureSnapshot));
    expect(merged.books.single.isDeleted, isTrue);
    expect(merged.visibleBooks, isEmpty);
    expect(merged.books.single.tombstoneAckedByDeviceIds, containsAll(['a']));
  });

  test('bookmark tombstone is retained and acknowledged instead of resurrected', () {
    final deleted = _bookmark(
      'bookmark',
      const SyncRevision(counter: 5, deviceId: 'a'),
      deletedAt: DateTime.utc(2000),
      updatedAt: DateTime.utc(2000),
      acks: const ['a'],
    );
    final stale = _bookmark('bookmark', const SyncRevision(counter: 4, deviceId: 'b'), updatedAt: DateTime.utc(2099));
    final merged = mergeManifests(
      _manifest('b', _book(bookmarks: [stale])),
      _manifest('a', _book(bookmarks: [deleted])),
    );

    final bookmark = merged.books.single.bookmarks.single;
    expect(bookmark.isDeleted, isTrue);
    expect(bookmark.tombstoneAckedByDeviceIds, containsAll(['a', 'b']));
    expect(
      tombstoneAcknowledgedByAllTrustedDevices(
        acknowledgedDeviceIds: bookmark.tombstoneAckedByDeviceIds,
        trustedDevices: merged.trustedDevices,
      ),
      isTrue,
    );
  });

  test('operationId remains idempotent after repository restart', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-sync-engine-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final secrets = _MemorySecretStore();
    final repository = _repository(directory, secrets);
    final storage = StorageService(repository: repository, secretStore: secrets);
    final engine = MetadataSyncEngine(storage);
    final remote = _manifest('b', _book(progressRevision: const SyncRevision(counter: 3, deviceId: 'b'), progress: 44));

    final first = await engine.applySnapshot(remote: remote, operationId: 'operation-1', protocolVersion: 3);
    final secondEngine = MetadataSyncEngine(
      StorageService(repository: _repository(directory, secrets), secretStore: secrets),
    );
    final second = await secondEngine.applySnapshot(remote: remote, operationId: 'operation-1', protocolVersion: 3);

    expect(first.status, SnapshotApplyStatus.applied);
    expect(second.status, SnapshotApplyStatus.duplicate);
    expect(second.manifest.books.single.progressPercent, 44);
    expect(second.manifest.appliedOperationIds.where((id) => id == 'operation-1'), hasLength(1));
  });

  test('revoked or permission-disabled devices cannot mutate or transfer', () {
    const authorization = SyncAuthorization();
    final revoked = TrustedDeviceRecord(deviceId: 'revoked', name: 'Old phone', deletedAt: DateTime.utc(2025));
    final metadataDisabled = TrustedDeviceRecord(
      deviceId: 'limited',
      name: 'Limited',
      canSyncMetadata: false,
      canTransferFiles: false,
    );
    final manifest = LibraryManifest(accountId: 'account', deviceId: 'a', trustedDevices: [revoked, metadataDisabled]);

    for (final deviceId in ['revoked', 'limited']) {
      expect(authorization.allows(manifest, deviceId, SyncCapability.metadata), isFalse);
      expect(authorization.allows(manifest, deviceId, SyncCapability.fileTransfer), isFalse);
    }
  });

  test('unsupported protocol version returns a controlled compatibility error', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-protocol-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final secrets = _MemorySecretStore();
    final engine = MetadataSyncEngine(
      StorageService(repository: _repository(directory, secrets), secretStore: secrets),
    );
    expect(() => engine.validateProtocol(1), throwsA(isA<ProtocolCompatibilityException>()));
  });

  test('legacy v2 envelope gets deterministic fallback operationId', () {
    final envelope = SyncEnvelope.fromJson({
      'type': 'library_snapshot',
      'accountId': 'account',
      'deviceId': 'legacy-device',
      'createdAt': '2025-01-01T00:00:00Z',
      'payload': <String, dynamic>{},
    });

    expect(envelope.protocolVersion, SyncEnvelope.minimumProtocolVersion);
    expect(envelope.operationId, 'legacy-legacy-device-library_snapshot-2025-01-01T00:00:00Z');
  });
}

LibraryManifest _manifest(String deviceId, BookRecord book) => LibraryManifest(
  accountId: 'account',
  deviceId: deviceId,
  logicalClock: 10,
  books: [book],
  trustedDevices: [
    TrustedDeviceRecord(deviceId: 'a', name: 'A', role: 'owner'),
    TrustedDeviceRecord(deviceId: 'b', name: 'B'),
  ],
);

BookRecord _book({
  String title = 'Book',
  double progress = 0,
  DateTime? updatedAt,
  DateTime? deletedAt,
  List<BookmarkRecord> bookmarks = const [],
  SyncRevision metadataRevision = SyncRevision.zero,
  SyncRevision progressRevision = SyncRevision.zero,
  List<String> tombstoneAcks = const [],
}) => BookRecord(
  id: 'book',
  title: title,
  fileName: 'book.txt',
  format: 'txt',
  sizeBytes: 1,
  contentSha256: List.filled(64, 'a').join(),
  updatedAt: updatedAt,
  deletedAt: deletedAt,
  progressPercent: progress,
  bookmarks: bookmarks,
  metadataRevision: metadataRevision,
  progressRevision: progressRevision,
  tombstoneAckedByDeviceIds: tombstoneAcks,
);

BookmarkRecord _bookmark(
  String id,
  SyncRevision revision, {
  DateTime? updatedAt,
  DateTime? deletedAt,
  List<String> acks = const [],
}) => BookmarkRecord(
  id: id,
  bookId: 'book',
  label: id,
  locator: id,
  revision: revision,
  updatedAt: updatedAt,
  deletedAt: deletedAt,
  tombstoneAckedByDeviceIds: acks,
);

LibraryRepository _repository(Directory directory, _MemorySecretStore secrets) => LibraryRepository(
  appDirectory: () async => directory,
  secretStore: secrets,
  createInitialManifest: () async => _manifest('a', _book()),
  normalize: (manifest) => manifest,
);

class _MemorySecretStore implements LibrarySecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
