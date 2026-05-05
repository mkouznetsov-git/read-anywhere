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
    await file.writeAsString(encoder.convert(manifest.toJson()), flush: true);
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
      devices[index] = devices[index].copyWith(
        name: normalizedName,
        role: devices[index].role == 'owner' ? 'owner' : role,
        lastSeenAt: DateTime.now().toUtc(),
      );
    } else {
      devices.add(TrustedDeviceRecord(
        deviceId: normalizedId,
        name: normalizedName,
        role: role,
      ));
    }
    devices.sort((a, b) => a.name.compareTo(b.name));
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


  LibraryManifest _ensureCurrentDeviceTrusted(LibraryManifest manifest) {
    final hasCurrent = manifest.trustedDevices.any((d) => d.deviceId == manifest.deviceId);
    if (hasCurrent) return manifest;
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
