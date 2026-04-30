import 'package:flutter_test/flutter_test.dart';
import 'package:read_anywhere/models/book.dart';
import 'package:read_anywhere/models/manifest.dart';
import 'package:read_anywhere/services/sync/merge.dart';

void main() {
  test('merge keeps local path but accepts newer progress', () {
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.txt',
      progressPercent: 10,
      progressVersion: 1,
      updatedByDeviceId: 'a',
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/remote/book.txt',
      progressPercent: 50,
      progressVersion: 2,
      updatedByDeviceId: 'b',
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.localPath, '/local/book.txt');
    expect(merged.books.single.progressPercent, 50);
    expect(merged.books.single.availableOnDeviceIds, ['a', 'b']);
  });

  test('merge remote-only book into local library', () {
    final remoteBook = BookRecord(
      id: 'book-2',
      title: 'Remote Book',
      fileName: 'remote.epub',
      format: 'epub',
      sizeBytes: 10,
      contentSha256: 'book-2',
      localPath: '/remote/remote.epub',
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a'),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.title, 'Remote Book');
    expect(merged.books.single.localPath, isNull);
    expect(merged.books.single.availableOnDeviceIds, ['b']);
  });

  test('merge bookmarks keeps both devices changes', () {
    final localBookmark = BookmarkRecord(
      id: 'bookmark-a',
      bookId: 'book-1',
      label: 'Mac bookmark',
      locator: 'txt-scroll:10',
    );
    final remoteBookmark = BookmarkRecord(
      id: 'bookmark-b',
      bookId: 'book-1',
      label: 'Android bookmark',
      locator: 'txt-scroll:20',
    );
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.txt',
      bookmarks: [localBookmark],
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/remote/book.txt',
      bookmarks: [remoteBookmark],
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.bookmarks.map((b) => b.id), [
      'bookmark-a',
      'bookmark-b',
    ]);
  });
}
