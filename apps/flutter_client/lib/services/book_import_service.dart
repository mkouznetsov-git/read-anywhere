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
    'epub',
    'mobi',
    'azw3',
    'cbz',
    'xps',
  ];

  Future<BookRecord?> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    return importFile(File(path));
  }

  Future<BookRecord> importFile(File sourceFile) async {
    final exists = await sourceFile.exists();
    if (!exists) throw ArgumentError('File does not exist: ${sourceFile.path}');

    final fileName = p.basename(sourceFile.path);
    final format = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final digest = await sha256.bind(sourceFile.openRead()).first;
    final sha = digest.toString();
    final size = await sourceFile.length();
    final title = p.basenameWithoutExtension(fileName);

    final destinationDir = await _storage.booksDir();
    final destinationPath = p.join(destinationDir.path, '$sha.$format');
    await sourceFile.copy(destinationPath);

    final book = BookRecord(
      id: sha,
      title: title,
      fileName: fileName,
      format: format,
      sizeBytes: size,
      contentSha256: sha,
      localPath: destinationPath,
    );
    await _storage.upsertBook(book);
    return book;
  }
}
