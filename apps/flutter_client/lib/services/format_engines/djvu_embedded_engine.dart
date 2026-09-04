import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

typedef _DjvuOpenC = Pointer<Void> Function(Pointer<Uint8> data, UintPtr len);
typedef _DjvuOpenDart = Pointer<Void> Function(Pointer<Uint8> data, int len);
typedef _DjvuCloseC = Void Function(Pointer<Void> document);
typedef _DjvuCloseDart = void Function(Pointer<Void> document);
typedef _DjvuRenderC = Int32 Function(
  Pointer<Void> document,
  Uint32 pageIndex,
  Uint32 targetWidth,
  Uint32 targetHeight,
  Pointer<Uint8> outRgba,
  UintPtr outLen,
);
typedef _DjvuRenderDart = int Function(
  Pointer<Void> document,
  int pageIndex,
  int targetWidth,
  int targetHeight,
  Pointer<Uint8> outRgba,
  int outLen,
);
typedef _DjvuPageInfoC = Int32 Function(Pointer<Void> document, Uint32 pageIndex, Pointer<_DjvuPageInfoNative> outInfo);
typedef _DjvuPageInfoDart = int Function(Pointer<Void> document, int pageIndex, Pointer<_DjvuPageInfoNative> outInfo);
typedef _DjvuRenderPngC = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  UintPtr len,
  Uint32 pageIndex,
  Uint32 targetWidth,
  Uint32 targetHeight,
  Pointer<UintPtr> outLen,
);
typedef _DjvuRenderPngDart = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  int len,
  int pageIndex,
  int targetWidth,
  int targetHeight,
  Pointer<UintPtr> outLen,
);
typedef _DjvuFreeBufferC = Void Function(Pointer<Uint8> ptr, UintPtr len);
typedef _DjvuFreeBufferDart = void Function(Pointer<Uint8> ptr, int len);

final class _DjvuPageInfoNative extends Struct {
  @Uint32()
  external int width;

  @Uint32()
  external int height;

  @Uint32()
  external int dpi;
}

class DjvuPageInfo {
  const DjvuPageInfo({required this.width, required this.height, required this.dpi});

  final int width;
  final int height;
  final int dpi;
}

/// Embedded DJVU renderer bridge.
///
/// Product rule: ReadArc must not call `ddjvu`, `djvused`, Homebrew, apt or a
/// server converter. This bridge loads the bundled native ReadArc engine when
/// it is present in the app package and returns PNG bytes for the requested
/// page. Missing native libraries are reported as `null`, so the Flutter UI can
/// stay alive and show a clear diagnostic instead of crashing.
class DjvuEmbeddedEngine {
  const DjvuEmbeddedEngine._();

  static Future<Uint8List?> renderPagePng({
    required String sourcePath,
    required int pageNumber,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    return compute<Map<String, Object>, Uint8List?>(_renderDjvuPagePngInIsolate, <String, Object>{
      'sourcePath': sourcePath,
      'pageNumber': pageNumber,
      'pixelWidth': pixelWidth,
      'pixelHeight': pixelHeight,
    });
  }

  static Future<List<DjvuPageInfo>> readPageInfos({required String sourcePath, required int pageCount}) async {
    final raw = await compute<Map<String, Object>, List<Map<String, int>>>(
      _readDjvuPageInfosInIsolate,
      <String, Object>{'sourcePath': sourcePath, 'pageCount': pageCount},
    );
    return raw
        .map((item) => DjvuPageInfo(width: item['width'] ?? 0, height: item['height'] ?? 0, dpi: item['dpi'] ?? 0))
        .toList(growable: false);
  }
}

Uint8List? _renderDjvuPagePngInIsolate(Map<String, Object> args) {
  final sourcePath = args['sourcePath']! as String;
  final pageNumber = args['pageNumber']! as int;
  final pixelWidth = args['pixelWidth']! as int;
  final pixelHeight = args['pixelHeight']! as int;

  final library = _tryOpenDjvuLibrary();
  if (library == null) return null;

  final bytes = File(sourcePath).readAsBytesSync();
  final fastPng = _tryRenderDjvuPagePngInNative(
    library: library,
    bytes: bytes,
    pageNumber: pageNumber,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );
  if (fastPng != null) return fastPng;

  final open = library.lookupFunction<_DjvuOpenC, _DjvuOpenDart>('readarc_djvu_open');
  final close = library.lookupFunction<_DjvuCloseC, _DjvuCloseDart>('readarc_djvu_close');
  final render = library.lookupFunction<_DjvuRenderC, _DjvuRenderDart>('readarc_djvu_render_page_rgba');

  final dataPtr = calloc<Uint8>(bytes.length);
  final outLen = pixelWidth * pixelHeight * 4;
  final outPtr = calloc<Uint8>(outLen);
  Pointer<Void> document = nullptr;
  try {
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);
    document = open(dataPtr, bytes.length);
    if (document == nullptr) return null;
    final rc = render(document, pageNumber - 1, pixelWidth, pixelHeight, outPtr, outLen);
    if (rc != 0) return null;
    final rgba = Uint8List.fromList(outPtr.asTypedList(outLen));
    final image = img.Image.fromBytes(width: pixelWidth, height: pixelHeight, bytes: rgba.buffer, numChannels: 4);
    return Uint8List.fromList(img.encodePng(image, level: 0));
  } catch (error) {
    debugPrint('ReadArc embedded DJVU render failed: $error');
    return null;
  } finally {
    if (document != nullptr) close(document);
    calloc.free(outPtr);
    calloc.free(dataPtr);
  }
}

Uint8List? _tryRenderDjvuPagePngInNative({
  required DynamicLibrary library,
  required Uint8List bytes,
  required int pageNumber,
  required int pixelWidth,
  required int pixelHeight,
}) {
  try {
    final renderPng = library.lookupFunction<_DjvuRenderPngC, _DjvuRenderPngDart>('readarc_djvu_render_page_png');
    final freeBuffer = library.lookupFunction<_DjvuFreeBufferC, _DjvuFreeBufferDart>('readarc_djvu_free_buffer');
    final dataPtr = calloc<Uint8>(bytes.length);
    final outLenPtr = calloc<UintPtr>();
    Pointer<Uint8> pngPtr = nullptr;
    try {
      dataPtr.asTypedList(bytes.length).setAll(0, bytes);
      pngPtr = renderPng(dataPtr, bytes.length, pageNumber - 1, pixelWidth, pixelHeight, outLenPtr);
      final outLen = outLenPtr.value;
      if (pngPtr == nullptr || outLen <= 0) return null;
      return Uint8List.fromList(pngPtr.asTypedList(outLen));
    } finally {
      if (pngPtr != nullptr && outLenPtr.value > 0) freeBuffer(pngPtr, outLenPtr.value);
      calloc.free(outLenPtr);
      calloc.free(dataPtr);
    }
  } catch (_) {
    return null;
  }
}

List<Map<String, int>> _readDjvuPageInfosInIsolate(Map<String, Object> args) {
  final sourcePath = args['sourcePath']! as String;
  final pageCount = args['pageCount']! as int;
  final library = _tryOpenDjvuLibrary();
  if (library == null || pageCount <= 0) return const <Map<String, int>>[];

  final open = library.lookupFunction<_DjvuOpenC, _DjvuOpenDart>('readarc_djvu_open');
  final close = library.lookupFunction<_DjvuCloseC, _DjvuCloseDart>('readarc_djvu_close');
  final pageInfo = library.lookupFunction<_DjvuPageInfoC, _DjvuPageInfoDart>('readarc_djvu_page_info');
  final bytes = File(sourcePath).readAsBytesSync();
  final dataPtr = calloc<Uint8>(bytes.length);
  final infoPtr = calloc<_DjvuPageInfoNative>();
  Pointer<Void> document = nullptr;
  try {
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);
    document = open(dataPtr, bytes.length);
    if (document == nullptr) return const <Map<String, int>>[];
    final result = <Map<String, int>>[];
    for (var i = 0; i < pageCount; i++) {
      final rc = pageInfo(document, i, infoPtr);
      if (rc == 0 && infoPtr.ref.width > 0 && infoPtr.ref.height > 0) {
        result.add(<String, int>{'width': infoPtr.ref.width, 'height': infoPtr.ref.height, 'dpi': infoPtr.ref.dpi});
      } else {
        result.add(const <String, int>{'width': 595, 'height': 842, 'dpi': 300});
      }
    }
    return result;
  } catch (error) {
    debugPrint('ReadArc embedded DJVU page info failed: $error');
    return const <Map<String, int>>[];
  } finally {
    if (document != nullptr) close(document);
    calloc.free(infoPtr);
    calloc.free(dataPtr);
  }
}

DynamicLibrary? _tryOpenDjvuLibrary() {
  final candidates = <String>[];
  if (Platform.isAndroid || Platform.isLinux) {
    candidates.add('libreadarc_djvu_engine.so');
  } else if (Platform.isMacOS) {
    final executable = File(Platform.resolvedExecutable);
    final macosDir = executable.parent;
    final contentsDir = macosDir.parent;
    candidates.add(
      '${contentsDir.path}${Platform.pathSeparator}Frameworks${Platform.pathSeparator}libreadarc_djvu_engine.dylib',
    );
    candidates.add('libreadarc_djvu_engine.dylib');
  } else if (Platform.isWindows) {
    candidates.add('readarc_djvu_engine.dll');
  }

  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (_) {}
  }
  return null;
}
