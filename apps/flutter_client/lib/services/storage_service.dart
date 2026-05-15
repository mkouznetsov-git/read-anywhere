import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

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
    // Canonical ReadArc data directory. Keep it stable so app updates do not
    // erase an existing development/test library.
    final documents = await getApplicationDocumentsDirectory();
    final appDirectory = Directory(p.join(documents.path, 'ReadArc'));
    await _restoreAppDataIfPrimaryIsEmpty(appDirectory, documents.path);
    if (!await appDirectory.exists()) {
      await appDirectory.create(recursive: true);
    }
    return appDirectory;
  }

  Future<void> _restoreAppDataIfPrimaryIsEmpty(Directory primary, String documentsPath) async {
    try {
      final primaryManifest = File(p.join(primary.path, 'manifest.json'));
      if (await primaryManifest.exists()) return;

      final candidates = <Directory>[
        Directory(p.join(documentsPath, 'ReadArc')),
      ];
      try {
        final support = await getApplicationSupportDirectory();
        candidates.addAll([
          Directory(p.join(support.path, 'ReadArc')),
        ]);
      } catch (_) {
        // Some platforms may not expose an application support directory.
      }

      for (final candidate in candidates) {
        if (candidate.path == primary.path) continue;
        final manifest = File(p.join(candidate.path, 'manifest.json'));
        if (!await manifest.exists()) continue;
        await primary.create(recursive: true);
        await _copyDirectoryContents(candidate, primary);
        return;
      }
    } catch (_) {
      // Never block startup because best-effort migration failed.
    }
  }

  Future<void> _copyDirectoryContents(Directory source, Directory target) async {
    if (!await source.exists()) return;
    if (!await target.exists()) await target.create(recursive: true);
    await for (final entity in source.list(recursive: false, followLinks: false)) {
      final destinationPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(destinationPath));
      } else if (entity is File) {
        final destination = File(destinationPath);
        if (!await destination.parent.exists()) await destination.parent.create(recursive: true);
        if (!await destination.exists()) {
          await entity.copy(destination.path);
        }
      }
    }
  }

  Future<Directory> booksDir() async {
    final dir = Directory(p.join((await appDir()).path, 'books'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> processedArtifactsDir() async {
    final dir = Directory(p.join((await appDir()).path, 'processed_artifacts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> processedArtifactDir(String bookId) async {
    final safeBookId = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final dir = Directory(p.join((await processedArtifactsDir()).path, safeBookId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> processedArtifactManifestFile(String bookId) async {
    return File(p.join((await processedArtifactDir(bookId)).path, 'artifact.json'));
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
      final deviceKeyPair = await _newDeviceSigningKeyPair();
      final manifest = LibraryManifest(
        accountId: 'account-${_uuid.v4()}',
        accountEncryptionKey: _newAccountEncryptionKey(),
        deviceSigningPublicKey: deviceKeyPair.publicKey,
        deviceSigningPrivateKey: deviceKeyPair.privateKey,
        deviceId: deviceId,
        deviceName: deviceName,
        trustedDevices: [
          TrustedDeviceRecord(
            deviceId: deviceId,
            name: deviceName,
            role: 'owner',
            publicKey: deviceKeyPair.publicKey,
            keyFingerprint: _fingerprint(deviceKeyPair.publicKey),
          ),
        ],
      );
      await saveManifest(manifest);
      return manifest;
    }
    final raw = await file.readAsString();
    final decoded = await _decodeManifestJson(raw, file);
    final manifest = LibraryManifest.fromJson(decoded);
    final withKey = manifest.accountEncryptionKey.trim().isEmpty
        ? manifest.copyWith(accountEncryptionKey: _newAccountEncryptionKey())
        : manifest;
    final withDeviceKey = await _ensureDeviceSigningKeys(withKey);
    final migrated = _ensureCurrentDeviceTrusted(withDeviceKey);
    if (!identical(migrated, manifest)) {
      await saveManifest(migrated);
    }
    return migrated;
  }

  Future<void> saveManifest(LibraryManifest manifest) async {
    final file = await manifestFile();
    await _backupManifestIfPresent(file);
    const encoder = JsonEncoder.withIndent('  ');
    final payload = encoder.convert(_normalizeManifest(manifest).toJson());
    final tmp = File('${file.path}.tmp-${_uuid.v4()}');
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      await tmp.copy(file.path);
      try {
        await tmp.delete();
      } catch (_) {
        // Best-effort cleanup only.
      }
    }
  }

  Future<Map<String, dynamic>> _decodeManifestJson(String raw, File manifestFile) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('manifest.json root is not an object');
    } on FormatException catch (error) {
      final repaired = _tryDecodeRepairedManifest(raw);
      if (repaired != null) {
        await _quarantineBrokenManifest(manifestFile, raw, error);
        await manifestFile.writeAsString(const JsonEncoder.withIndent('  ').convert(repaired), flush: true);
        return repaired;
      }
      final backup = await _loadLatestValidManifestBackup();
      if (backup != null) {
        await _quarantineBrokenManifest(manifestFile, raw, error);
        await manifestFile.writeAsString(const JsonEncoder.withIndent('  ').convert(backup), flush: true);
        return backup;
      }
      rethrow;
    }
  }

  Map<String, dynamic>? _tryDecodeRepairedManifest(String raw) {
    final candidate = _firstCompleteJsonObject(raw);
    if (candidate == null || candidate.trim() == raw.trim()) return null;
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Try backups below.
    }
    return null;
  }

  String? _firstCompleteJsonObject(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escaping = false;
    for (var i = start; i < raw.length; i++) {
      final code = raw.codeUnitAt(i);
      if (inString) {
        if (escaping) {
          escaping = false;
        } else if (code == 0x5C) {
          escaping = true;
        } else if (code == 0x22) {
          inString = false;
        }
        continue;
      }
      if (code == 0x22) {
        inString = true;
      } else if (code == 0x7B || code == 0x5B) {
        depth++;
      } else if (code == 0x7D || code == 0x5D) {
        depth--;
        if (depth == 0) return raw.substring(start, i + 1);
        if (depth < 0) return null;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _loadLatestValidManifestBackup() async {
    try {
      final backupDir = Directory(p.join((await appDir()).path, 'manifest_backups'));
      if (!await backupDir.exists()) return null;
      final backups = await backupDir
          .list()
          .where((entity) => entity is File && p.basename(entity.path).startsWith('manifest_'))
          .cast<File>()
          .toList();
      backups.sort((a, b) => b.path.compareTo(a.path));
      for (final backup in backups) {
        try {
          final decoded = jsonDecode(await backup.readAsString());
          if (decoded is Map<String, dynamic>) return decoded;
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        } catch (_) {
          // Try the next backup.
        }
      }
    } catch (_) {
      // Recovery is best-effort only.
    }
    return null;
  }

  Future<void> _quarantineBrokenManifest(File manifestFile, String raw, Object error) async {
    try {
      final recoveryDir = Directory(p.join((await appDir()).path, 'manifest_recovery'));
      if (!await recoveryDir.exists()) await recoveryDir.create(recursive: true);
      final ts = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final broken = File(p.join(recoveryDir.path, 'broken_manifest_$ts.json'));
      await broken.writeAsString(raw, flush: true);
      final note = File(p.join(recoveryDir.path, 'broken_manifest_$ts.txt'));
      await note.writeAsString('Recovered from manifest parse error: $error\nSource: ${manifestFile.path}\n', flush: true);
    } catch (_) {
      // Never fail startup because recovery diagnostics cannot be written.
    }
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
      return device.copyWith(
        name: normalized,
        publicKey: manifest.deviceSigningPublicKey,
        keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
        lastSeenAt: DateTime.now().toUtc(),
      );
    }).toList();
    final updated = manifest.copyWith(deviceName: normalized, trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }


  Future<LibraryManifest> trustDevice({
    required String deviceId,
    required String name,
    String role = 'device',
    String publicKey = '',
  }) async {
    final normalizedId = deviceId.trim();
    final normalizedName = name.trim().isEmpty ? 'Устройство' : name.trim();
    final normalizedPublicKey = publicKey.trim();
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
        publicKey: normalizedPublicKey.isEmpty ? existing.publicKey : normalizedPublicKey,
        keyFingerprint: normalizedPublicKey.isEmpty ? existing.keyFingerprint : _fingerprint(normalizedPublicKey),
        lastSeenAt: DateTime.now().toUtc(),
        clearRevocation: true,
      );
    } else {
      devices.add(TrustedDeviceRecord(
        deviceId: normalizedId,
        name: normalizedName,
        role: role,
        publicKey: normalizedPublicKey,
        keyFingerprint: _fingerprint(normalizedPublicKey),
      ));
    }
    final updated = manifest.copyWith(trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> replaceAccountFromPairing({
    required String accountId,
    required String accountEncryptionKey,
    required String ownerDeviceId,
    required String ownerDeviceName,
    String ownerDevicePublicKey = '',
  }) async {
    final current = await loadManifest();
    await saveManifest(current.copyWith(
      accountId: accountId,
      accountEncryptionKey: accountEncryptionKey.trim().isEmpty
          ? current.accountEncryptionKey
          : accountEncryptionKey.trim(),
    ));
    final manifest = await loadManifest();
    final withOwner = await trustDevice(
      deviceId: ownerDeviceId,
      name: ownerDeviceName,
      role: 'owner',
      publicKey: ownerDevicePublicKey,
    );
    return trustDevice(
      deviceId: withOwner.deviceId,
      name: withOwner.deviceName,
      role: 'device',
      publicKey: withOwner.deviceSigningPublicKey,
    );
  }


  /// Creates a fresh local device identity when this installation was previously
  /// revoked and the user scans a new owner QR code. Reusing the old deviceId
  /// would immediately match the owner's revocation tombstone again, so a
  /// reconnected phone/tablet must come back as a new trusted device. The old
  /// revoked record is preserved for audit/history.
  Future<LibraryManifest> rotateCurrentDeviceIdentityForPairing() async {
    final manifest = await loadManifest();
    if (!manifest.isCurrentDeviceRevoked) return manifest;

    final newDeviceId = 'device-${_uuid.v4()}';
    final newKeyPair = await _newDeviceSigningKeyPair();
    final now = DateTime.now().toUtc();
    final devices = [
      ...manifest.trustedDevices,
      TrustedDeviceRecord(
        deviceId: newDeviceId,
        name: manifest.deviceName,
        role: 'device',
        publicKey: newKeyPair.publicKey,
        keyFingerprint: _fingerprint(newKeyPair.publicKey),
        addedAt: now,
        lastSeenAt: now,
      ),
    ];

    final updated = manifest.copyWith(
      deviceId: newDeviceId,
      deviceSigningPublicKey: newKeyPair.publicKey,
      deviceSigningPrivateKey: newKeyPair.privateKey,
      trustedDevices: devices,
    );
    await saveManifest(updated);
    return updated;
  }



  Future<LibraryManifest> revokeTrustedDevice(String deviceId, {String reason = 'revoked_by_owner'}) async {
    final manifest = await loadManifest();
    if (deviceId == manifest.deviceId) {
      throw ArgumentError('Нельзя отозвать доступ у текущего устройства');
    }
    final now = DateTime.now().toUtc();
    final devices = manifest.trustedDevices.map((device) {
      if (device.deviceId != deviceId) return device;
      return device.copyWith(
        deletedAt: now,
        lastSeenAt: now,
        revokedByDeviceId: manifest.deviceId,
        revokedReason: reason,
      );
    }).toList();
    final updated = manifest.copyWith(trustedDevices: devices);
    await saveManifest(updated);
    return updated;
  }

  Future<LibraryManifest> removeTrustedDevice(String deviceId) => revokeTrustedDevice(deviceId);

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
      if (device.isRevoked) return device;
      return device.copyWith(
        name: manifest.deviceName,
        publicKey: manifest.deviceSigningPublicKey,
        keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
        lastSeenAt: now,
        clearRevocation: true,
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
    final books = manifest.books.map((book) {
      if (!book.isDeleted) return book;
      final localPath = book.localPath?.trim() ?? '';
      if (localPath.isEmpty) return book;

      // Safety repair for stale remote tombstones. A normal user-initiated
      // delete clears localPath first. If a deleted record still has a local
      // file path, the book was almost certainly hidden by an older remote
      // tombstone during sync. Keep the user's local library visible.
      final availableOn = <String>{
        ...book.availableOnDeviceIds,
        manifest.deviceId,
      }.toList()
        ..sort();
      return book.copyWith(
        clearDeletedAt: true,
        availableOnDeviceIds: availableOn,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList()
      ..sort((a, b) {
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
      if (existing.isRevoked != device.isRevoked) {
        if (device.isRevoked) devices[device.deviceId] = device;
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


  Future<void> _backupManifestIfPresent(File manifestFile) async {
    try {
      if (!await manifestFile.exists()) return;
      final backupDir = Directory(p.join((await appDir()).path, 'manifest_backups'));
      if (!await backupDir.exists()) await backupDir.create(recursive: true);
      final ts = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final backup = File(p.join(backupDir.path, 'manifest_$ts.json'));
      await manifestFile.copy(backup.path);

      final backups = await backupDir
          .list()
          .where((entity) => entity is File && p.basename(entity.path).startsWith('manifest_'))
          .cast<File>()
          .toList();
      backups.sort((a, b) => b.path.compareTo(a.path));
      for (final stale in backups.skip(20)) {
        try {
          await stale.delete();
        } catch (_) {
          // Backup cleanup is best-effort only.
        }
      }
    } catch (_) {
      // Never fail the main manifest write because of backup problems.
    }
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
      // If another trusted owner revoked this device, never silently restore it on
      // startup. The UI can still show local library data, but sync must stop.
      if (current.isRevoked) return manifest;
      final currentKey = manifest.deviceSigningPublicKey;
      if (current.name == manifest.deviceName && current.publicKey == currentKey) return manifest;
      devices[index] = current.copyWith(
        name: manifest.deviceName,
        publicKey: currentKey,
        keyFingerprint: _fingerprint(currentKey),
        lastSeenAt: DateTime.now().toUtc(),
        clearRevocation: true,
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
          publicKey: manifest.deviceSigningPublicKey,
          keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
        ),
      ],
    );
  }

  Future<LibraryManifest> _ensureDeviceSigningKeys(LibraryManifest manifest) async {
    if (manifest.deviceSigningPublicKey.trim().isNotEmpty &&
        manifest.deviceSigningPrivateKey.trim().isNotEmpty) {
      return manifest;
    }
    final keyPair = await _newDeviceSigningKeyPair();
    return manifest.copyWith(
      deviceSigningPublicKey: keyPair.publicKey,
      deviceSigningPrivateKey: keyPair.privateKey,
    );
  }

  Future<_DeviceSigningKeyPair> _newDeviceSigningKeyPair() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final keyPairData = await keyPair.extract();
    return _DeviceSigningKeyPair(
      publicKey: _base64UrlNoPadding(keyPairData.publicKey.bytes),
      privateKey: _base64UrlNoPadding(keyPairData.bytes),
    );
  }

  String _fingerprint(String publicKey) {
    final normalized = publicKey.trim();
    if (normalized.isEmpty) return '';
    final digest = crypto.sha256.convert(utf8.encode(normalized)).bytes;
    final full = _base64UrlNoPadding(digest);
    return '${full.substring(0, 8)}…${full.substring(full.length - 8)}';
  }

  String _base64UrlNoPadding(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

  String _newAccountEncryptionKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
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


class _DeviceSigningKeyPair {
  const _DeviceSigningKeyPair({required this.publicKey, required this.privateKey});

  final String publicKey;
  final String privateKey;
}
