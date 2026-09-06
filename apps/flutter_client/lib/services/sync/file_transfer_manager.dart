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

enum FileChunkAppendStatus { appended, duplicate, premature, invalid }

class FileChunkAppendResult {
  const FileChunkAppendResult({required this.status, required this.receivedBytes, required this.nextChunkIndex});

  final FileChunkAppendStatus status;
  final int receivedBytes;
  final int nextChunkIndex;
}

/// Persists transfer intent so a new SyncService can resume the same `.part` file.
class FileTransferManager {
  FileTransferManager({required Future<Directory> Function() appDirectory}) : this._(appDirectory);

  FileTransferManager._(this._appDirectory);

  final Future<Directory> Function() _appDirectory;

  Future<PreparedFileTransfer> prepare(PendingFileTransfer transfer) async {
    _validate(transfer);
    final directory = await _incomingDirectory();
    final journal = File(p.join(directory.path, '${transfer.bookId}.transfer.json'));
    final tempJournal = File('${journal.path}.tmp');
    final previousJournal = File('${journal.path}.prev');
    await tempJournal.writeAsString(jsonEncode(transfer.toJson()), flush: true);
    await _readValidJournal(tempJournal);
    if (await previousJournal.exists()) await previousJournal.delete();
    if (await journal.exists()) await journal.rename(previousJournal.path);
    await tempJournal.rename(journal.path);
    if (await previousJournal.exists()) await previousJournal.delete();

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
    final bookIds = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      for (final suffix in const ['.transfer.json', '.transfer.json.tmp', '.transfer.json.prev']) {
        if (name.endsWith(suffix)) {
          bookIds.add(name.substring(0, name.length - suffix.length));
        }
      }
    }
    for (final bookId in bookIds) {
      try {
        final recovered = await _recoverJournal(directory, bookId);
        if (recovered != null) result.add(recovered);
      } catch (_) {
        // Leave broken generations in place for diagnostics and continue.
      }
    }
    return result..sort((a, b) => a.bookId.compareTo(b.bookId));
  }

  Future<FileChunkAppendResult> appendChunk({
    required PendingFileTransfer transfer,
    required File partialFile,
    required int expectedChunkIndex,
    required int chunkIndex,
    required int offset,
    required int totalChunks,
    required int totalBytes,
    required String sha256,
    required List<int> data,
  }) async {
    _validate(transfer);
    final receivedBytes = await partialFile.length();
    if (chunkIndex < expectedChunkIndex) {
      return FileChunkAppendResult(
        status: FileChunkAppendStatus.duplicate,
        receivedBytes: receivedBytes,
        nextChunkIndex: expectedChunkIndex,
      );
    }
    if (chunkIndex > expectedChunkIndex) {
      return FileChunkAppendResult(
        status: FileChunkAppendStatus.premature,
        receivedBytes: receivedBytes,
        nextChunkIndex: expectedChunkIndex,
      );
    }

    final expectedTotalChunks = (transfer.expectedBytes + transfer.chunkSize - 1) ~/ transfer.chunkSize;
    final isFinalChunk = receivedBytes + data.length == transfer.expectedBytes;
    final valid =
        offset == receivedBytes &&
        receivedBytes == expectedChunkIndex * transfer.chunkSize &&
        totalBytes == transfer.expectedBytes &&
        totalChunks == expectedTotalChunks &&
        sha256 == transfer.expectedSha256 &&
        data.isNotEmpty &&
        data.length <= transfer.chunkSize &&
        (isFinalChunk || data.length == transfer.chunkSize) &&
        receivedBytes + data.length <= transfer.expectedBytes;
    if (!valid) {
      return FileChunkAppendResult(
        status: FileChunkAppendStatus.invalid,
        receivedBytes: receivedBytes,
        nextChunkIndex: expectedChunkIndex,
      );
    }

    await partialFile.writeAsBytes(data, mode: FileMode.append, flush: true);
    final newLength = await partialFile.length();
    if (newLength != receivedBytes + data.length) {
      throw const FileSystemException('Chunk append did not reach the expected durable length');
    }
    return FileChunkAppendResult(
      status: FileChunkAppendStatus.appended,
      receivedBytes: newLength,
      nextChunkIndex: expectedChunkIndex + 1,
    );
  }

  Future<bool> verifySha256(File file, String expectedSha256) async {
    if (!await file.exists()) return false;
    final actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == expectedSha256.toLowerCase();
  }

  Future<void> markCompleted(String bookId) async {
    final directory = await _incomingDirectory();
    for (final suffix in const ['.transfer.json', '.transfer.json.tmp', '.transfer.json.prev']) {
      final journal = File(p.join(directory.path, '$bookId$suffix'));
      if (await journal.exists()) await journal.delete();
    }
  }

  Future<void> discard(String bookId) async {
    final directory = await _incomingDirectory();
    for (final suffix in const ['.part', '.transfer.json', '.transfer.json.tmp', '.transfer.json.prev']) {
      final file = File(p.join(directory.path, '$bookId$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> _incomingDirectory() async {
    final directory = Directory(p.join((await _appDirectory()).path, 'incoming'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<PendingFileTransfer?> _recoverJournal(Directory directory, String bookId) async {
    final journal = File(p.join(directory.path, '$bookId.transfer.json'));
    final temp = File('${journal.path}.tmp');
    final previous = File('${journal.path}.prev');
    for (final candidate in [temp, journal, previous]) {
      try {
        final transfer = await _readValidJournal(candidate);
        if (transfer.bookId != bookId) continue;
        if (candidate.path != journal.path) {
          if (await journal.exists()) await journal.delete();
          await candidate.rename(journal.path);
        }
        return transfer;
      } catch (_) {
        // Try the next durable generation.
      }
    }
    return null;
  }

  Future<PendingFileTransfer> _readValidJournal(File file) async {
    if (!await file.exists()) {
      throw const FileSystemException('Transfer journal does not exist');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Transfer journal is not an object');
    }
    final transfer = PendingFileTransfer.fromJson(Map<String, dynamic>.from(decoded));
    _validate(transfer);
    return transfer;
  }

  void _validate(PendingFileTransfer transfer) {
    if (transfer.bookId.trim().isEmpty ||
        transfer.transferId.trim().isEmpty ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(transfer.bookId) ||
        transfer.bookId.contains('..')) {
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
