import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/book.dart';

class DirectTransferServer {
  DirectTransferServer({this.onStarted});

  final void Function(int port)? onStarted;
  final _uuid = const Uuid();
  final _shares = <String, _DirectFileShare>{};
  HttpServer? _server;

  Future<void> ensureStarted() async {
    if (_server != null) return;
    for (final port in const [8790, 8791, 0]) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
        _server = server;
        server.listen(
          (request) => unawaited(_handle(request)),
          onError: (Object error) => debugPrint('Direct file server error: $error'),
          cancelOnError: false,
        );
        onStarted?.call(server.port);
        return;
      } catch (_) {
        if (port == 0) rethrow;
      }
    }
  }

  Future<List<String>> createShareUrls({required BookRecord book, required File file}) async {
    try {
      await ensureStarted();
      final port = _server?.port;
      if (port == null) return const [];
      final token = _uuid.v4().replaceAll('-', '');
      _shares[token] = _DirectFileShare(
        bookId: book.id,
        file: file,
        fileName: book.fileName,
        sha256: book.contentSha256,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );
      _shares.removeWhere((_, share) => share.expiresAt.isBefore(DateTime.now().toUtc()));
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final urls = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.address.startsWith('169.254.')) continue;
          urls.add('http://${address.address}:$port/direct-file/$token');
        }
      }
      return urls.toSet().toList()..sort();
    } catch (error) {
      debugPrint('Cannot create Direct/LAN share: $error');
      return const [];
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if ((request.method != 'GET' && request.method != 'HEAD') ||
          segments.length != 2 ||
          segments[0] != 'direct-file') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final share = _shares[segments[1]];
      if (share == null || share.expiresAt.isBefore(DateTime.now().toUtc())) {
        _shares.remove(segments[1]);
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (!await share.file.exists()) {
        request.response.statusCode = HttpStatus.gone;
        await request.response.close();
        return;
      }
      final size = await share.file.length();
      var start = 0;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (match != null) start = int.tryParse(match.group(1) ?? '') ?? 0;
      start = start.clamp(0, size).toInt();
      request.response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
        ..set('X-ReadArc-Book-Id', share.bookId)
        ..set('X-ReadArc-Sha256', share.sha256)
        ..set('X-ReadArc-File-Name', Uri.encodeComponent(share.fileName));
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${size - 1}/$size');
      }
      request.response.contentLength = size - start;
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        await share.file.openRead(start).pipe(request.response);
      }
    } catch (error) {
      debugPrint('Direct file request failed: $error');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _shares.clear();
  }

  void revokeAllShares() => _shares.clear();
}

class _DirectFileShare {
  const _DirectFileShare({
    required this.bookId,
    required this.file,
    required this.fileName,
    required this.sha256,
    required this.expiresAt,
  });

  final String bookId;
  final File file;
  final String fileName;
  final String sha256;
  final DateTime expiresAt;
}
