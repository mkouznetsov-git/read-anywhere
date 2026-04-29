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
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.localPath, '/local/book.txt');
    expect(merged.books.single.progressPercent, 50);
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
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a'),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.title, 'Remote Book');
    expect(merged.books.single.localPath, isNull);
  });
}
