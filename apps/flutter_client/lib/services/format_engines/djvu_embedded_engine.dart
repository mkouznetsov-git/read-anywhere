import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

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
}

Uint8List? _renderDjvuPagePngInIsolate(Map<String, Object> args) {
  final sourcePath = args['sourcePath']! as String;
  final pageNumber = args['pageNumber']! as int;
  final pixelWidth = args['pixelWidth']! as int;
  final pixelHeight = args['pixelHeight']! as int;

  final library = _tryOpenDjvuLibrary();
  if (library == null) return null;

  final open = library.lookupFunction<_DjvuOpenC, _DjvuOpenDart>('readarc_djvu_open');
  final close = library.lookupFunction<_DjvuCloseC, _DjvuCloseDart>('readarc_djvu_close');
  final render = library.lookupFunction<_DjvuRenderC, _DjvuRenderDart>('readarc_djvu_render_page_rgba');

  final bytes = File(sourcePath).readAsBytesSync();
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
    final image = img.Image.fromBytes(
      width: pixelWidth,
      height: pixelHeight,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image, level: 1));
  } catch (error) {
    debugPrint('ReadArc embedded DJVU render failed: $error');
    return null;
  } finally {
    if (document != nullptr) close(document);
    calloc.free(outPtr);
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
    candidates.add('${contentsDir.path}${Platform.pathSeparator}Frameworks${Platform.pathSeparator}libreadarc_djvu_engine.dylib');
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
