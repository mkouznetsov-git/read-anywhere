import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class PendingFileTransfer {
  const PendingFileTransfer({
    required this.transferId,
    required this.bookId,
    required this.fileName,
    required this.format,
    required this.expectedSha256,
    required this.expectedBytes,
    required this.chunkSize,
  });

  final String transferId;
  final String bookId;
  final String fileName;
  final String format;
  final String expectedSha256;
  final int expectedBytes;
  final int chunkSize;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'transferId': transferId,
    'bookId': bookId,
    'fileName': fileName,
    'format': format,
    'expectedSha256': expectedSha256,
    'expectedBytes': expectedBytes,
    'chunkSize': chunkSize,
  };

  factory PendingFileTransfer.fromJson(Map<String, dynamic> json) => PendingFileTransfer(
    transferId: json['transferId']?.toString() ?? '',
    bookId: json['bookId']?.toString() ?? '',
    fileName: json['fileName']?.toString() ?? '',
    format: json['format']?.toString() ?? '',
    expectedSha256: json['expectedSha256']?.toString() ?? '',
    expectedBytes: (json['expectedBytes'] as num?)?.toInt() ?? 0,
    chunkSize: (json['chunkSize'] as num?)?.toInt() ?? 1024 * 1024,
  );
}

class PreparedFileTransfer {
  const PreparedFileTransfer({required this.partialFile, required this.resumeBytes, required this.nextChunkIndex});

  final File partialFile;
  final int resumeBytes;
  final int nextChunkIndex;
}

/// Persists transfer intent so a new SyncService can resume the same `.part` file.
class FileTransferManager {
  FileTransferManager({required Future<Directory> Function() appDirectory}) : _appDirectory = appDirectory;

  final Future<Directory> Function() _appDirectory;

  Future<PreparedFileTransfer> prepare(PendingFileTransfer transfer) async {
    _validate(transfer);
    final directory = await _incomingDirectory();
    final journal = File(p.join(directory.path, '${transfer.bookId}.transfer.json'));
    final tempJournal = File('${journal.path}.tmp');
    await tempJournal.writeAsString(jsonEncode(transfer.toJson()), flush: true);
    final verified = PendingFileTransfer.fromJson(
      Map<String, dynamic>.from(jsonDecode(await tempJournal.readAsString()) as Map),
    );
    _validate(verified);
    if (await journal.exists()) await journal.delete();
    await tempJournal.rename(journal.path);

    final partial = File(p.join(directory.path, '${transfer.bookId}.part'));
    if (!await partial.exists()) await partial.create(recursive: true);
    var length = await partial.length();
    if (length > transfer.expectedBytes) {
      await partial.writeAsBytes(const [], flush: true);
      length = 0;
    }
    final aligned = (length ~/ transfer.chunkSize) * transfer.chunkSize;
    if (aligned != length) {
      final file = await partial.open(mode: FileMode.writeOnlyAppend);
      try {
        await file.truncate(aligned);
      } finally {
        await file.close();
      }
      length = aligned;
    }
    return PreparedFileTransfer(
      partialFile: partial,
      resumeBytes: length,
      nextChunkIndex: length ~/ transfer.chunkSize,
    );
  }

  Future<List<PendingFileTransfer>> loadPending() async {
    final directory = await _incomingDirectory();
    final result = <PendingFileTransfer>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.transfer.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) continue;
        final transfer = PendingFileTransfer.fromJson(Map<String, dynamic>.from(decoded));
        _validate(transfer);
        result.add(transfer);
      } catch (_) {
        // Leave a broken journal in place for diagnostics and continue.
      }
    }
    return result..sort((a, b) => a.bookId.compareTo(b.bookId));
  }

  Future<bool> verifySha256(File file, String expectedSha256) async {
    if (!await file.exists()) return false;
    final actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == expectedSha256.toLowerCase();
  }

  Future<void> markCompleted(String bookId) async {
    final directory = await _incomingDirectory();
    final journal = File(p.join(directory.path, '$bookId.transfer.json'));
    if (await journal.exists()) await journal.delete();
  }

  Future<void> discard(String bookId) async {
    final directory = await _incomingDirectory();
    for (final suffix in const ['.part', '.transfer.json', '.transfer.json.tmp']) {
      final file = File(p.join(directory.path, '$bookId$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> _incomingDirectory() async {
    final directory = Directory(p.join((await _appDirectory()).path, 'incoming'));
    await directory.create(recursive: true);
    return directory;
  }

  void _validate(PendingFileTransfer transfer) {
    if (transfer.bookId.trim().isEmpty || transfer.transferId.trim().isEmpty) {
      throw const FormatException('Transfer journal has no bookId/transferId');
    }
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(transfer.expectedSha256)) {
      throw const FormatException('Transfer journal has invalid SHA-256');
    }
    if (transfer.expectedBytes < 0 || transfer.chunkSize <= 0) {
      throw const FormatException('Transfer journal has invalid size/chunkSize');
    }
  }
}
