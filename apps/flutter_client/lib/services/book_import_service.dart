import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'storage_service.dart';

class BookImportService {
  BookImportService(this._storage);

  final StorageService _storage;

  static const supportedExtensions = <String>[
    'pdf',
    'doc',
    'docx',
    'txt',
    'fb2',
    'djvu',
    'djv',
    'epub',
    'chm',
    'mobi',
    'azw3',
    'cbz',
    'xps',
  ];

  Future<BookRecord?> pickAndImport() async {
    // Android document providers often do not advertise niche extensions such as
    // .fb2 with a useful MIME type. FileType.custom can therefore hide valid FB2
    // files. On Android we let the picker show all files and validate the
    // extension ourselves after selection.
    final result = await FilePicker.platform.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : supportedExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      throw UnsupportedError('Формат .$extension пока не поддерживается ReadArc');
    }
    return importFile(File(path));
  }

  Future<BookRecord> importFile(File sourceFile) async {
    final exists = await sourceFile.exists();
    if (!exists) throw ArgumentError('File does not exist: ${sourceFile.path}');

    final manifest = await _storage.loadManifest();
    final fileName = p.basename(sourceFile.path);
    final format = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final digest = await sha256.bind(sourceFile.openRead()).first;
    final sha = digest.toString();
    final size = await sourceFile.length();
    final title = p.basenameWithoutExtension(fileName);

    final destinationDir = await _storage.booksDir();
    final destinationPath = p.join(destinationDir.path, '$sha.$format');
    await sourceFile.copy(destinationPath);

    BookRecord? existing;
    for (final candidate in manifest.books) {
      if (candidate.id == sha) {
        existing = candidate;
        break;
      }
    }

    final availableOn = <String>{
      ...?existing?.availableOnDeviceIds,
      manifest.deviceId,
    }.toList()
      ..sort();

    final book = existing == null
        ? BookRecord(
            id: sha,
            title: title,
            fileName: fileName,
            format: format,
            sizeBytes: size,
            contentSha256: sha,
            localPath: destinationPath,
            availableOnDeviceIds: availableOn,
            updatedByDeviceId: manifest.deviceId,
          )
        : existing.copyWith(
            title: title,
            fileName: fileName,
            format: format,
            sizeBytes: size,
            contentSha256: sha,
            localPath: destinationPath,
            availableOnDeviceIds: availableOn,
            clearDeletedAt: true,
            updatedAt: DateTime.now().toUtc(),
          );
    await _storage.upsertBook(book);
    return book;
  }
}
