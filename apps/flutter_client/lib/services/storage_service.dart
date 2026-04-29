import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/book.dart';
import '../models/manifest.dart';

class StorageService {
  StorageService();

  final _uuid = const Uuid();

  Future<Directory> appDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final appDirectory = Directory(p.join(dir.path, 'ReadAnywhere'));
    if (!await appDirectory.exists()) {
      await appDirectory.create(recursive: true);
    }
    return appDirectory;
  }

  Future<Directory> booksDir() async {
    final dir = Directory(p.join((await appDir()).path, 'books'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> manifestFile() async {
    return File(p.join((await appDir()).path, 'manifest.json'));
  }

  Future<LibraryManifest> loadManifest() async {
    final file = await manifestFile();
    if (!await file.exists()) {
      final manifest = LibraryManifest(
        accountId: 'local-account-${_uuid.v4()}',
        deviceId: 'device-${_uuid.v4()}',
      );
      await saveManifest(manifest);
      return manifest;
    }
    final raw = await file.readAsString();
    return LibraryManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveManifest(LibraryManifest manifest) async {
    final file = await manifestFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(manifest.toJson()), flush: true);
  }

  Future<void> upsertBook(BookRecord book) async {
    final manifest = await loadManifest();
    final books = [...manifest.books];
    final index = books.indexWhere((b) => b.id == book.id);
    if (index >= 0) {
      books[index] = book;
    } else {
      books.add(book);
    }
    await saveManifest(manifest.copyWith(books: books));
  }

  Future<void> updateProgress({
    required String bookId,
    required double progressPercent,
    required String locator,
  }) async {
    final manifest = await loadManifest();
    final updatedBooks = manifest.books.map((book) {
      if (book.id != bookId) return book;
      return book.copyWith(
        progressPercent: progressPercent.clamp(0, 100),
        currentLocator: locator,
        progressVersion: book.progressVersion + 1,
        updatedByDeviceId: manifest.deviceId,
      );
    }).toList();
    await saveManifest(manifest.copyWith(books: updatedBooks));
  }

  Future<void> addBookmark({
    required String bookId,
    required String label,
    required String locator,
  }) async {
    final manifest = await loadManifest();
    final updatedBooks = manifest.books.map((book) {
      if (book.id != bookId) return book;
      final bookmark = BookmarkRecord(
        bookId: bookId,
        label: label,
        locator: locator,
      );
      return book.copyWith(bookmarks: [...book.bookmarks, bookmark]);
    }).toList();
    await saveManifest(manifest.copyWith(books: updatedBooks));
  }
}
