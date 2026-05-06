import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/book.dart';
import '../models/manifest.dart';
import '../models/sync_settings.dart';

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

  Future<File> syncSettingsFile() async {
    return File(p.join((await appDir()).path, 'sync_settings.json'));
  }

  Future<LibraryManifest> loadManifest() async {
    final file = await manifestFile();
    if (!await file.exists()) {
      final deviceId = 'device-${_uuid.v4()}';
      final deviceName = _defaultDeviceName();
      final manifest = LibraryManifest(
        accountId: 'account-${_uuid.v4()}',
        deviceId: deviceId,
        deviceName: deviceName,
        trustedDevices: [
          TrustedDeviceRecord(deviceId: deviceId, name: deviceName, role: 'owner'),
        ],
      );
      await saveManifest(manifest);
      return manifest;
    }
    final raw = await file.readAsString();
    final manifest = LibraryManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final migrated = _ensureCurrentDeviceTrusted(manifest);
    if (!identical(migrated, manifest)) {
      await saveManifest(migrated);
    }
    return migrated;
  }

  Future<void> saveManifest(LibraryManifest manifest) async {
    final file = await manifestFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(_normalizeManifest(manifest).toJson()), flush: true);
  }

  Future<SyncSettings> loadSyncSettings() async {
    final file = await syncSettingsFile();
    if (!await file.exists()) return const SyncSettings();
    final raw = await file.readAsString();
    return SyncSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSyncSettings(SyncSettings settings) async {
    final file = await syncSettingsFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(settings.toJson()), flush: true);
  }

  Future<LibraryManifest> changeAccountId(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('accountId не может быть пустым');
    }
    final manifest = await loadManifest();
    final updated = manifest.copyWith(accountId: normalized);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> changeDeviceName(String deviceName) async {
    final normalized = deviceName.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Название устройства не может быть пустым');
    }
    final manifest = await loadManifest();
    final devices = manifest.trustedDevices.map((device) {
      if (device.deviceId != manifest.deviceId) return device;
      return device.copyWith(name: normalized, lastSeenAt: DateTime.now().toUtc());
    }).toList();
    final updated = manifest.copyWith(deviceName: normalized, trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }


  Future<LibraryManifest> trustDevice({
    required String deviceId,
    required String name,
    String role = 'device',
  }) async {
    final normalizedId = deviceId.trim();
    final normalizedName = name.trim().isEmpty ? 'Устройство' : name.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError('deviceId не может быть пустым');
    }
    final manifest = await loadManifest();
    final devices = [...manifest.trustedDevices];
    final index = devices.indexWhere((d) => d.deviceId == normalizedId);
    if (index >= 0) {
      final existing = devices[index];
      devices[index] = existing.copyWith(
        name: normalizedName,
        role: existing.role == 'owner' ? 'owner' : role,
        lastSeenAt: DateTime.now().toUtc(),
        clearDeletedAt: true,
      );
    } else {
      devices.add(TrustedDeviceRecord(
        deviceId: normalizedId,
        name: normalizedName,
        role: role,
      ));
    }
    final updated = manifest.copyWith(trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> replaceAccountFromPairing({
    required String accountId,
    required String ownerDeviceId,
    required String ownerDeviceName,
  }) async {
    final manifest = await changeAccountId(accountId);
    final withOwner = await trustDevice(
      deviceId: ownerDeviceId,
      name: ownerDeviceName,
      role: 'owner',
    );
    return trustDevice(
      deviceId: withOwner.deviceId,
      name: withOwner.deviceName,
      role: 'device',
    );
  }



  Future<LibraryManifest> removeTrustedDevice(String deviceId) async {
    final manifest = await loadManifest();
    if (deviceId == manifest.deviceId) {
      throw ArgumentError('Нельзя удалить текущее устройство из доверенных');
    }
    final now = DateTime.now().toUtc();
    final devices = manifest.trustedDevices.map((device) {
      if (device.deviceId != deviceId) return device;
      return device.copyWith(deletedAt: now, lastSeenAt: now);
    }).toList();
    final updated = manifest.copyWith(trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> pruneDeletedTrustedDevices() async {
    final manifest = await loadManifest();
    final kept = manifest.trustedDevices.where((device) {
      if (device.deviceId == manifest.deviceId) return true;
      return !device.isDeleted;
    }).toList();
    final updated = manifest.copyWith(trustedDevices: kept);
    await saveManifest(updated);
    return updated;
  }


  Future<LibraryManifest> touchCurrentDevice() async {
    final manifest = await loadManifest();
    final now = DateTime.now().toUtc();
    final devices = manifest.trustedDevices.map((device) {
      if (device.deviceId != manifest.deviceId) return device;
      return device.copyWith(
        name: manifest.deviceName,
        lastSeenAt: now,
        clearDeletedAt: true,
      );
    }).toList();
    final updated = manifest.copyWith(trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }

  Future<void> upsertBook(BookRecord book) async {
    final manifest = await loadManifest();
    final books = [...manifest.books];
    final index = books.indexWhere((b) => b.id == book.id);
    if (index >= 0) {
      final existing = books[index];
      final availableOn = <String>{
        ...existing.availableOnDeviceIds,
        ...book.availableOnDeviceIds,
      }.toList()
        ..sort();
      books[index] = existing.copyWith(
        title: book.title,
        fileName: book.fileName,
        format: book.format,
        sizeBytes: book.sizeBytes,
        contentSha256: book.contentSha256,
        localPath: book.localPath,
        updatedAt: DateTime.now().toUtc(),
        clearDeletedAt: true,
        availableOnDeviceIds: availableOn,
      );
    } else {
      books.add(book);
    }
    await saveManifest(manifest.copyWith(books: books));
  }

  Future<LibraryManifest> updateProgress({
    required String bookId,
    required double progressPercent,
    required String locator,
  }) async {
    final manifest = await loadManifest();
    final updatedBooks = manifest.books.map((book) {
      if (book.id != bookId) return book;
      return book.copyWith(
        progressPercent: progressPercent.clamp(0, 100).toDouble(),
        currentLocator: locator,
        progressVersion: book.progressVersion + 1,
        updatedByDeviceId: manifest.deviceId,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
    final updated = manifest.copyWith(books: updatedBooks);
    await saveManifest(updated);
    return updated;
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
      return book.copyWith(
        bookmarks: [...book.bookmarks, bookmark],
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
    await saveManifest(manifest.copyWith(books: updatedBooks));
  }




  Future<LibraryManifest> removeLocalBookCopy(String bookId) async {
    final manifest = await loadManifest();
    var found = false;
    final updatedBooks = <BookRecord>[];
    for (final book in manifest.books) {
      if (book.id != bookId) {
        updatedBooks.add(book);
        continue;
      }
      found = true;
      await _deleteLocalBookFileIfSafe(book.localPath);
      final availableOn = book.availableOnDeviceIds
          .where((deviceId) => deviceId != manifest.deviceId)
          .toList()
        ..sort();
      updatedBooks.add(book.copyWith(
        clearLocalPath: true,
        availableOnDeviceIds: availableOn,
        updatedAt: DateTime.now().toUtc(),
      ));
    }
    if (!found) throw StateError('Книга не найдена в manifest: $bookId');
    final updated = manifest.copyWith(books: updatedBooks);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> deleteBookFromLibrary(String bookId) async {
    final manifest = await loadManifest();
    var found = false;
    final now = DateTime.now().toUtc();
    final updatedBooks = <BookRecord>[];
    for (final book in manifest.books) {
      if (book.id != bookId) {
        updatedBooks.add(book);
        continue;
      }
      found = true;
      await _deleteLocalBookFileIfSafe(book.localPath);
      updatedBooks.add(book.copyWith(
        clearLocalPath: true,
        availableOnDeviceIds: const [],
        deletedAt: now,
        updatedAt: now,
      ));
    }
    if (!found) throw StateError('Книга не найдена в manifest: $bookId');
    final updated = manifest.copyWith(books: updatedBooks);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> markBookDownloaded({
    required String bookId,
    required String localPath,
  }) async {
    final manifest = await loadManifest();
    var found = false;
    final updatedBooks = manifest.books.map((book) {
      if (book.id != bookId) return book;
      found = true;
      final availableOn = <String>{
        ...book.availableOnDeviceIds,
        manifest.deviceId,
      }.toList()
        ..sort();
      return book.copyWith(
        localPath: localPath,
        availableOnDeviceIds: availableOn,
        clearDeletedAt: true,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
    if (!found) {
      throw StateError('Книга не найдена в manifest: $bookId');
    }
    final updated = manifest.copyWith(books: updatedBooks);
    await saveManifest(updated);
    return updated;
  }



  LibraryManifest _normalizeManifest(LibraryManifest manifest) {
    final books = [...manifest.books]..sort((a, b) {
      if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
      return compareBooksForLibrary(a, b);
    });
    final devices = <String, TrustedDeviceRecord>{};
    for (final device in manifest.trustedDevices) {
      final existing = devices[device.deviceId];
      if (existing == null) {
        devices[device.deviceId] = device;
        continue;
      }
      final existingMarker = existing.deletedAt ?? existing.lastSeenAt;
      final deviceMarker = device.deletedAt ?? device.lastSeenAt;
      if (deviceMarker.isAfter(existingMarker)) devices[device.deviceId] = device;
    }
    final sortedDevices = devices.values.toList()
      ..sort((a, b) {
        if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
        final ownerCompare = (b.role == 'owner' ? 1 : 0).compareTo(a.role == 'owner' ? 1 : 0);
        if (ownerCompare != 0) return ownerCompare;
        final currentCompare = (b.deviceId == manifest.deviceId ? 1 : 0).compareTo(a.deviceId == manifest.deviceId ? 1 : 0);
        if (currentCompare != 0) return currentCompare;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return manifest.copyWith(books: books, trustedDevices: sortedDevices);
  }

  Future<void> _deleteLocalBookFileIfSafe(String? localPath) async {
    if (localPath == null || localPath.trim().isEmpty) return;
    try {
      final file = File(localPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Deleting the manifest entry must not fail just because the file was
      // already removed or the OS denied cleanup. The next import/download will
      // rewrite the local copy.
    }
  }

  LibraryManifest _ensureCurrentDeviceTrusted(LibraryManifest manifest) {
    final devices = [...manifest.trustedDevices];
    final index = devices.indexWhere((d) => d.deviceId == manifest.deviceId);
    if (index >= 0) {
      final current = devices[index];
      if (!current.isDeleted && current.name == manifest.deviceName) return manifest;
      devices[index] = current.copyWith(
        name: manifest.deviceName,
        lastSeenAt: DateTime.now().toUtc(),
        clearDeletedAt: true,
      );
      return manifest.copyWith(trustedDevices: devices);
    }
    return manifest.copyWith(
      trustedDevices: [
        ...manifest.trustedDevices,
        TrustedDeviceRecord(
          deviceId: manifest.deviceId,
          name: manifest.deviceName,
          role: manifest.trustedDevices.isEmpty ? 'owner' : 'device',
        ),
      ],
    );
  }

  String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } catch (_) {
      // Some platforms may restrict hostname access.
    }
    return 'Моё устройство';
  }
}
