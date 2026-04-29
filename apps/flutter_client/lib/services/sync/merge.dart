import '../../models/book.dart';
import '../../models/manifest.dart';

LibraryManifest mergeManifests(LibraryManifest local, LibraryManifest remote) {
  final mergedById = <String, BookRecord>{};

  for (final book in local.books) {
    mergedById[book.id] = book;
  }

  for (final remoteBook in remote.books) {
    final localBook = mergedById[remoteBook.id];
    if (localBook == null) {
      mergedById[remoteBook.id] = BookRecord(
        id: remoteBook.id,
        title: remoteBook.title,
        fileName: remoteBook.fileName,
        format: remoteBook.format,
        sizeBytes: remoteBook.sizeBytes,
        contentSha256: remoteBook.contentSha256,
        localPath: null,
        addedAt: remoteBook.addedAt,
        updatedAt: remoteBook.updatedAt,
        progressPercent: remoteBook.progressPercent,
        currentLocator: remoteBook.currentLocator,
        progressVersion: remoteBook.progressVersion,
        updatedByDeviceId: remoteBook.updatedByDeviceId,
        bookmarks: remoteBook.bookmarks,
      );
      continue;
    }
    mergedById[remoteBook.id] = _mergeBook(localBook, remoteBook);
  }

  return local.copyWith(
    updatedAt: DateTime.now().toUtc(),
    books: mergedById.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );
}

BookRecord _mergeBook(BookRecord local, BookRecord remote) {
  final progressWinner = _progressCompare(local, remote) >= 0 ? local : remote;
  final bookmarks = _mergeBookmarks(local.bookmarks, remote.bookmarks);

  // Important: localPath is never accepted from another device. A remote book may
  // be visible in the library but still not downloaded on this device.
  return local.copyWith(
    title: remote.updatedAt.isAfter(local.updatedAt) ? remote.title : local.title,
    fileName: remote.fileName.isNotEmpty ? remote.fileName : local.fileName,
    format: remote.format.isNotEmpty ? remote.format : local.format,
    sizeBytes: remote.sizeBytes > 0 ? remote.sizeBytes : local.sizeBytes,
    contentSha256: remote.contentSha256,
    localPath: local.localPath,
    progressPercent: progressWinner.progressPercent,
    currentLocator: progressWinner.currentLocator,
    progressVersion: progressWinner.progressVersion,
    updatedByDeviceId: progressWinner.updatedByDeviceId,
    bookmarks: bookmarks,
    updatedAt: DateTime.now().toUtc(),
  );
}

int _progressCompare(BookRecord a, BookRecord b) {
  final version = a.progressVersion.compareTo(b.progressVersion);
  if (version != 0) return version;
  final time = a.updatedAt.compareTo(b.updatedAt);
  if (time != 0) return time;
  return a.updatedByDeviceId.compareTo(b.updatedByDeviceId);
}

List<BookmarkRecord> _mergeBookmarks(
  List<BookmarkRecord> local,
  List<BookmarkRecord> remote,
) {
  final byId = <String, BookmarkRecord>{};
  for (final item in [...local, ...remote]) {
    final existing = byId[item.id];
    if (existing == null || item.updatedAt.isAfter(existing.updatedAt)) {
      byId[item.id] = item;
    }
  }
  return byId.values.where((b) => !b.isDeleted).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}
