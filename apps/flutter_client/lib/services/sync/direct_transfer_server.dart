import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/book.dart';

class DirectTransferServer {
  DirectTransferServer({
    this.onStarted,
    this.enabled = true,
    this.includeLoopback = false,
    this.streamChunkSize = 64 * 1024,
    this.streamChunkDelay = Duration.zero,
  }) : assert(streamChunkSize > 0);

  final void Function(int port)? onStarted;
  final bool enabled;
  final bool includeLoopback;
  final int streamChunkSize;
  final Duration streamChunkDelay;
  final _uuid = const Uuid();
  final _shares = <String, _DirectFileShare>{};
  final _activeResponses = <HttpResponse>{};
  HttpServer? _server;

  Future<void> ensureStarted() async {
    if (!enabled) return;
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
      if (includeLoopback) {
        urls.add('http://127.0.0.1:$port/direct-file/$token');
      }
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
      var end = size == 0 ? 0 : size - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null ? null : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range.trim());
      if (match != null) {
        start = int.tryParse(match.group(1) ?? '') ?? 0;
        final requestedEnd = int.tryParse(match.group(2) ?? '');
        if (requestedEnd != null) end = requestedEnd.clamp(start, end).toInt();
      }
      if (size > 0 && start >= size) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await request.response.close();
        return;
      }
      start = start.clamp(0, size).toInt();
      final responseBytes = size == 0 ? 0 : end - start + 1;
      request.response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
        ..set('X-ReadArc-Book-Id', share.bookId)
        ..set('X-ReadArc-Sha256', share.sha256)
        ..set('X-ReadArc-File-Name', Uri.encodeComponent(share.fileName));
      if (match != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      }
      request.response.contentLength = responseBytes;
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        await _streamShare(
          token: segments[1],
          share: share,
          response: request.response,
          start: start,
          endExclusive: size == 0 ? 0 : end + 1,
        );
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
    revokeAllShares();
    await _server?.close(force: true);
    _server = null;
  }

  void revokeAllShares() {
    _shares.clear();
    for (final response in _activeResponses.toList(growable: false)) {
      unawaited(_closeResponse(response));
    }
  }

  Future<void> _streamShare({
    required String token,
    required _DirectFileShare share,
    required HttpResponse response,
    required int start,
    required int endExclusive,
  }) async {
    _activeResponses.add(response);
    RandomAccessFile? source;
    try {
      source = await share.file.open(mode: FileMode.read);
      await source.setPosition(start);
      var remaining = endExclusive - start;
      while (remaining > 0 && identical(_shares[token], share)) {
        final bytes = await source.read(remaining.clamp(0, streamChunkSize).toInt());
        if (bytes.isEmpty) break;
        response.add(bytes);
        await response.flush();
        remaining -= bytes.length;
        if (streamChunkDelay > Duration.zero) {
          await Future<void>.delayed(streamChunkDelay);
        }
      }
      await response.close();
    } finally {
      _activeResponses.remove(response);
      await source?.close();
    }
  }

  Future<void> _closeResponse(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {
      // The peer may have already closed while revocation was propagated.
    }
  }
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
