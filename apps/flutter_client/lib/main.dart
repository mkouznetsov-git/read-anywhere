import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pdfx/pdfx.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/book.dart';
import 'models/manifest.dart';
import 'models/sync_settings.dart';
import 'services/book_import_service.dart';
import 'services/storage_service.dart';
import 'services/sync/sync_service.dart';
import 'ui/app_theme.dart';

void main() {
  runApp(const ReadAnywhereApp());
}

class ReadAnywhereApp extends StatefulWidget {
  const ReadAnywhereApp({super.key});

  @override
  State<ReadAnywhereApp> createState() => _ReadAnywhereAppState();
}

class _ReadAnywhereAppState extends State<ReadAnywhereApp> {
  final _storage = StorageService();
  late final _sync = SyncService(_storage);

  @override
  void initState() {
    super.initState();
    unawaited(_autoConnectSync());
  }

  Future<void> _autoConnectSync() async {
    try {
      final settings = await _storage.loadSyncSettings();
      if (!settings.autoConnect) return;
      if (settings.usesOfficialPlaceholder) return;
      await _sync.connect(relayUrl: settings.effectiveRelayUrl);
    } catch (error) {
      debugPrint('ReadAnywhere auto-connect failed: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_sync.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ReadAnywhere',
      theme: ReadAnywhereTheme.light(),
      home: LibraryScreen(storage: _storage, sync: _sync),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.storage,
    required this.sync,
  });

  final StorageService storage;
  final SyncService sync;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _importService = BookImportService(widget.storage);
  LibraryManifest? _manifest;
  bool _busy = false;
  bool _healthBusy = false;
  bool _pairingBusy = false;
  bool _logExpanded = false;
  PairingInvite? _pairingInvite;
  StreamSubscription<LibraryManifest>? _syncSubscription;

  @override
  void initState() {
    super.initState();
    _syncSubscription = widget.sync.manifestChanges.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    unawaited(_syncSubscription?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final manifest = await widget.storage.loadManifest();
    if (mounted) setState(() => _manifest = manifest);
  }

  Future<void> _addBook() async {
    setState(() => _busy = true);
    try {
      final book = await _importService.pickAndImport();
      if (book != null) {
        await widget.sync.broadcastLibrarySnapshot(reason: 'book_imported');
      }
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось добавить книгу: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadBook(BookRecord book) async {
    if (!widget.sync.state.value.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет подключения к relay.')),
      );
      return;
    }

    final started = await widget.sync.requestBookFile(book);
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось начать скачивание. Проверьте подключение к relay.')),
      );
    }
  }

  Future<void> _cancelBookDownload(BookRecord book) async {
    await widget.sync.cancelBookFileDownload(book.id);
  }


  Future<void> _removeLocalCopy(BookRecord book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить файл с этого устройства?'),
        content: Text(
          'Книга «${book.title}» останется в библиотеке аккаунта, но файл будет удалён с этого устройства. Позже её можно будет скачать снова с другого устройства.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить файл'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.storage.removeLocalBookCopy(book.id);
      await widget.sync.broadcastLibrarySnapshot(reason: 'local_copy_removed');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить файл: $error')),
      );
    }
  }

  Future<void> _deleteFromLibrary(BookRecord book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить книгу из библиотеки?'),
        content: Text(
          'Книга «${book.title}» исчезнет из библиотеки аккаунта на всех устройствах после синхронизации. Локальный файл на этом устройстве будет удалён.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить из библиотеки'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.storage.deleteBookFromLibrary(book.id);
      await widget.sync.broadcastLibrarySnapshot(reason: 'book_deleted');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить книгу: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.visibleBooks ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('ReadAnywhere'),
        actions: [
          ValueListenableBuilder<SyncStateSnapshot>(
            valueListenable: widget.sync.state,
            builder: (context, syncState, _) {
              return IconButton(
                tooltip: syncState.connected
                    ? 'Синхронизация подключена'
                    : 'Синхронизация',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SyncScreen(
                        storage: widget.storage,
                        sync: widget.sync,
                      ),
                    ),
                  );
                  await _reload();
                },
                icon: Icon(
                  syncState.connected
                      ? Icons.sync_rounded
                      : Icons.sync_disabled_rounded,
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addBook,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        label: const Text('Добавить книгу'),
      ),
      body: manifest == null
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
              ? const _EmptyLibrary()
              : ValueListenableBuilder<SyncStateSnapshot>(
                  valueListenable: widget.sync.state,
                  builder: (context, syncState, _) {
                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: books.length,
                      itemBuilder: (context, index) {
                        final book = books[index];
                        final transfer = syncState.downloadForBook(book.id);
                        return _BookCard(
                          book: book,
                          transfer: transfer,
                          onDownload: !book.isDownloaded && transfer?.active != true
                              ? () => _downloadBook(book)
                              : null,
                          onCancelDownload: transfer?.active == true
                              ? () => _cancelBookDownload(book)
                              : null,
                          onRemoveLocalCopy: book.isDownloaded
                              ? () => _removeLocalCopy(book)
                              : null,
                          onDeleteFromLibrary: () => _deleteFromLibrary(book),
                          onOpen: book.isDownloaded
                              ? () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ReaderScreen(
                                        book: book,
                                        storage: widget.storage,
                                        sync: widget.sync,
                                      ),
                                    ),
                                  );
                                  await _reload();
                                }
                              : null,
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Библиотека пока пуста. Добавьте книгу — она будет скопирована в локальное хранилище устройства.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onOpen,
    required this.onDownload,
    required this.onCancelDownload,
    required this.onRemoveLocalCopy,
    required this.onDeleteFromLibrary,
    required this.transfer,
  });

  final BookRecord book;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRemoveLocalCopy;
  final VoidCallback onDeleteFromLibrary;
  final FileTransferSnapshot? transfer;

  @override
  Widget build(BuildContext context) {
    final progressValue = (book.progressPercent.clamp(0, 100) / 100).toDouble();
    final progressText = book.progressPercent.clamp(0, 100).toStringAsFixed(1);
    final transfer = this.transfer;
    final isDownloading = transfer?.active == true;
    final hasDownloadError = transfer?.hasError == true;
    final showTransfer = transfer != null && !book.isDownloaded && (isDownloading || hasDownloadError);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                book.format.toUpperCase(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(value: progressValue),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '$progressText%',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (showTransfer && transfer != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: transfer.progressPercent.clamp(0, 100) / 100,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasDownloadError
                      ? (transfer.error ?? 'Ошибка скачивания')
                      : transfer.statusText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDownloading)
              IconButton(
                tooltip: 'Отменить скачивание',
                onPressed: onCancelDownload,
                icon: const Icon(Icons.cancel_outlined),
              )
            else
              IconButton(
                tooltip: book.isDownloaded ? 'Читать' : 'Скачать на это устройство',
                onPressed: book.isDownloaded ? onOpen : onDownload,
                icon: Icon(book.isDownloaded
                    ? Icons.menu_book_rounded
                    : Icons.cloud_download_outlined),
              ),
            PopupMenuButton<_BookAction>(
              tooltip: 'Действия с книгой',
              onSelected: (action) {
                switch (action) {
                  case _BookAction.removeLocalCopy:
                    onRemoveLocalCopy?.call();
                    break;
                  case _BookAction.deleteFromLibrary:
                    onDeleteFromLibrary();
                    break;
                }
              },
              itemBuilder: (context) => [
                if (book.isDownloaded)
                  const PopupMenuItem(
                    value: _BookAction.removeLocalCopy,
                    child: Text('Удалить файл с этого устройства'),
                  ),
                const PopupMenuItem(
                  value: _BookAction.deleteFromLibrary,
                  child: Text('Удалить из библиотеки'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _BookAction { removeLocalCopy, deleteFromLibrary }

class ReaderScreen extends StatelessWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.storage,
    required this.sync,
  });

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    switch (book.format.toLowerCase()) {
      case 'txt':
        return _TxtReaderScreen(book: book, storage: storage, sync: sync);
      case 'fb2':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync);
      case 'pdf':
        return _PdfReaderScreen(book: book, storage: storage, sync: sync);
      default:
        return Scaffold(
          appBar: AppBar(title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          body: _UnsupportedReaderPlaceholder(book: book),
        );
    }
  }
}

enum _TextSourceKind { txt, fb2 }

class _TxtReaderScreen extends StatefulWidget {
  const _TxtReaderScreen({
    required this.book,
    required this.storage,
    required this.sync,
    this.sourceKind = _TextSourceKind.txt,
  });

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;
  final _TextSourceKind sourceKind;

  @override
  State<_TxtReaderScreen> createState() => _TxtReaderScreenState();
}

class _TxtReaderScreenState extends State<_TxtReaderScreen> {
  // TXT reader v4: one native Flutter ListView with fixed-height text rows.
  // This is deliberately boring: fixed item extent gives macOS a stable scroll
  // extent, Android gets a normal scrollbar, and the saved locator is the first
  // source character of the line touching the top of the viewport.
  static const _fontSize = 18.0;
  static const _heightFactor = 1.65;
  static const _readerTextStyle = TextStyle(fontSize: _fontSize, height: _heightFactor);
  static const _lineExtent = _fontSize * _heightFactor;
  static const _horizontalReaderPadding = 24.0;
  static const _topPadding = 18.0;
  static const _bottomPadding = 28.0;

  final _scrollController = ScrollController();
  String? _rawText;
  List<_TextLine>? _lines;
  int _totalChars = 0;
  int _pendingAnchorChar = 0;
  double _lastUsableWidth = 0;
  bool _restoringPosition = false;
  bool _didInitialRestore = false;
  String? _loadError;
  Timer? _saveDebounce;
  Timer? _resizeDebounce;
  Timer? _progressRedrawThrottle;
  double _lastProgress = 0;
  BookRecord? _runtimeBook;
  _TextAnchorLocator? _lastKnownLocator;
  bool _fullScreen = false;

  BookRecord get _book => _runtimeBook ?? widget.book;

  Future<BookRecord> _loadCurrentBook() async {
    final manifest = await widget.storage.loadManifest();
    for (final book in manifest.books) {
      if (book.id == widget.book.id) return book;
    }
    return widget.book;
  }

  @override
  void initState() {
    super.initState();
    _lastProgress = widget.book.progressPercent;
    _scrollController.addListener(_onScrollPositionChanged);
    _load();
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    _saveDebounce?.cancel();
    _progressRedrawThrottle?.cancel();
    final locator = _currentLocator() ?? _lastKnownLocator;
    if (locator != null) {
      unawaited(_saveProgress(locator));
    }
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final book = await _loadCurrentBook();
    if (!mounted) return;
    _runtimeBook = book;
    if (book.localPath == null) {
      setState(() => _loadError = 'Файл книги не скачан на это устройство');
      return;
    }

    try {
      final file = File(book.localPath!);
      if (!await file.exists()) throw StateError('Файл отсутствует: ${book.localPath}');
      final bytes = await file.readAsBytes();
      final decoded = _decodeTextFile(bytes);
      final raw = widget.sourceKind == _TextSourceKind.fb2
          ? _extractFb2Text(decoded)
          : _normalizeText(decoded);
      final totalChars = raw.length;
      final targetChar = _targetCharForBook(book, totalChars);
      if (!mounted) return;
      setState(() {
        _rawText = raw;
        _totalChars = totalChars;
        _pendingAnchorChar = targetChar;
        _lastKnownLocator = targetChar >= totalChars && totalChars > 0
            ? _locatorForEnd()
            : _locatorForAnchorChar(targetChar);
        _lastProgress = _lastKnownLocator?.progressPercent ?? 0;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      final label = widget.sourceKind == _TextSourceKind.fb2 ? 'FB2' : 'TXT';
      setState(() => _loadError = 'Не удалось открыть $label: $error');
    }
  }

  void _ensureLinesForWidth(double maxWidth) {
    final raw = _rawText;
    if (raw == null) return;
    final usableWidth = (maxWidth - (_horizontalReaderPadding * 2)).clamp(180.0, 2000.0).toDouble();
    if (_lines != null && (usableWidth - _lastUsableWidth).abs() < 8) return;

    // Keep the current top source position across window resizes. Debouncing
    // avoids doing text wrapping dozens of times while the user drags the edge.
    final anchor = _currentLocator()?.anchorChar ?? _pendingAnchorChar;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) return;
      final built = _buildDisplayLines(raw, usableWidth);
      setState(() {
        _lines = built.isEmpty ? [const _TextLine(text: '', startChar: 0, endChar: 0)] : built;
        _lastUsableWidth = usableWidth;
        _pendingAnchorChar = anchor.clamp(0, _totalChars).toInt();
      });
      _scheduleRestoreScroll();
    });
  }

  void _scheduleRestoreScroll() {
    if (_rawText == null || _lines == null) return;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        for (var attempt = 0; attempt < 16; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 16 : 35));
          if (!mounted || !_scrollController.hasClients) continue;
          final target = _offsetForAnchorChar(_pendingAnchorChar);
          _scrollController.jumpTo(target.clamp(0.0, _scrollController.position.maxScrollExtent));
          final locator = _currentLocator() ?? _lastKnownLocator;
          _lastKnownLocator = locator;
          _lastProgress = locator?.progressPercent ?? _lastProgress;
          _didInitialRestore = true;
          if (mounted) setState(() {});
          break;
        }
      } finally {
        _restoringPosition = false;
      }
    });
  }

  int _targetCharForBook(BookRecord book, int totalChars) {
    if (totalChars <= 0) return 0;
    final decoded = _tryDecodeLocatorJson(book.currentLocator);
    if (decoded != null) {
      final type = decoded['type'];
      if (type == 'txt-line-anchor-v1' ||
          type == 'fb2-line-anchor-v1' ||
          type == 'txt-top-anchor-v3' ||
          type == 'txt-top-anchor-v2' ||
          type == 'txt-top-anchor-v1' ||
          type == 'txt-anchor-v1') {
        return ((decoded['anchorChar'] as num?)?.round() ?? 0).clamp(0, totalChars).toInt();
      }
      if (type == 'txt-page-v3' || type == 'txt-page-v2') {
        return ((decoded['anchorChar'] as num?)?.round() ??
                (decoded['startChar'] as num?)?.round() ??
                0)
            .clamp(0, totalChars)
            .toInt();
      }
      if (type == 'txt-page-v1') {
        final startChar = (decoded['startChar'] as num?)?.round();
        if (startChar != null) return startChar.clamp(0, totalChars).toInt();
        final pageIndex = ((decoded['pageIndex'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        final pageCount = ((decoded['pageCount'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        if (pageCount > 0) return ((pageIndex / pageCount) * totalChars).round().clamp(0, totalChars).toInt();
      }
      if (type == 'txt-char-v1') {
        return ((decoded['charIndex'] as num?)?.round() ?? 0).clamp(0, totalChars).toInt();
      }
    }
    final progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
    return ((progress / 100.0) * totalChars).round().clamp(0, totalChars).toInt();
  }

  Map<String, dynamic>? _tryDecodeLocatorJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {}
    return null;
  }

  _TextAnchorLocator? _currentLocator() {
    if (_totalChars <= 0) return null;
    if (!_scrollController.hasClients) return _lastKnownLocator ?? _locatorForAnchorChar(_pendingAnchorChar);
    if (_isAtBottom()) return _locatorForEnd();
    final lines = _lines;
    if (lines == null || lines.isEmpty) return _lastKnownLocator;
    final lineIndex = _topLineIndexFromOffset(_scrollController.offset);
    final safeIndex = lineIndex.clamp(0, lines.length - 1).toInt();
    final line = lines[safeIndex];
    return _TextAnchorLocator(
      anchorChar: line.startChar.clamp(0, _totalChars).toInt(),
      totalChars: _totalChars,
      lineIndex: safeIndex,
      lineCount: lines.length,
      scrollOffset: _scrollController.offset,
      maxScrollExtent: _scrollController.position.maxScrollExtent,
      viewportWidth: _lastUsableWidth,
    );
  }

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    return position.maxScrollExtent <= 0 || position.extentAfter <= 8;
  }

  _TextAnchorLocator _locatorForEnd() {
    final lines = _lines ?? const <_TextLine>[];
    return _TextAnchorLocator(
      anchorChar: _totalChars,
      totalChars: _totalChars,
      lineIndex: lines.isEmpty ? 0 : lines.length - 1,
      lineCount: lines.length,
      scrollOffset: _scrollController.hasClients ? _scrollController.offset : null,
      maxScrollExtent: _scrollController.hasClients ? _scrollController.position.maxScrollExtent : null,
      viewportWidth: _lastUsableWidth,
    );
  }

  _TextAnchorLocator _locatorForAnchorChar(int anchorChar) {
    final lines = _lines ?? const <_TextLine>[];
    final index = _lineIndexForChar(lines, anchorChar.clamp(0, _totalChars).toInt());
    return _TextAnchorLocator(
      anchorChar: anchorChar.clamp(0, _totalChars).toInt(),
      totalChars: _totalChars,
      lineIndex: index,
      lineCount: lines.length,
      viewportWidth: _lastUsableWidth,
    );
  }

  int _topLineIndexFromOffset(double offset) {
    final contentOffset = (offset - _topPadding).clamp(0.0, double.infinity).toDouble();
    return (contentOffset / _lineExtent).floor();
  }

  double _offsetForAnchorChar(int anchorChar) {
    final lines = _lines ?? const <_TextLine>[];
    if (lines.isEmpty) return 0;
    if (anchorChar >= _totalChars && _totalChars > 0 && _scrollController.hasClients) {
      return _scrollController.position.maxScrollExtent;
    }
    final index = _lineIndexForChar(lines, anchorChar.clamp(0, _totalChars).toInt());
    return _topPadding + index * _lineExtent;
  }

  void _onScrollPositionChanged() {
    if (_restoringPosition || !_didInitialRestore) return;
    final locator = _currentLocator();
    if (locator == null) return;
    _lastKnownLocator = locator;
    _lastProgress = locator.progressPercent;
    _scheduleProgressRedraw();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_saveProgress(locator));
    });
  }

  void _scheduleProgressRedraw() {
    if (_progressRedrawThrottle?.isActive ?? false) return;
    _progressRedrawThrottle = Timer(const Duration(milliseconds: 80), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _saveProgress(_TextAnchorLocator locator) async {
    final manifest = await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: locator.progressPercent,
      locator: locator.toJsonString(
        type: widget.sourceKind == _TextSourceKind.fb2 ? 'fb2-line-anchor-v1' : 'txt-line-anchor-v1',
      ),
    );
    for (final book in manifest.books) {
      if (book.id == widget.book.id) {
        _runtimeBook = book;
        break;
      }
    }
    await widget.sync.broadcastLibrarySnapshot(reason: 'progress_updated');
  }

  Future<void> _addBookmark() async {
    final locator = _currentLocator();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: locator?.toJsonString(
            type: widget.sourceKind == _TextSourceKind.fb2 ? 'fb2-line-anchor-v1' : 'txt-line-anchor-v1',
          ) ??
          _book.currentLocator,
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  @override
  Widget build(BuildContext context) {
    final raw = _rawText;
    final lines = _lines;
    return Scaffold(
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: lines != null ? _addBookmark : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'txt-bookmark-${widget.book.id}',
                  tooltip: 'Добавить закладку',
                  onPressed: lines != null ? _addBookmark : null,
                  child: const Icon(Icons.bookmark_add_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'txt-exit-fullscreen-${widget.book.id}',
                  tooltip: 'Выйти из полного экрана',
                  onPressed: () => setState(() => _fullScreen = false),
                  child: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ],
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : raw == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _ensureLinesForWidth(constraints.maxWidth);
                          final currentLines = _lines;
                          if (currentLines == null) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return SelectionArea(
                            child: Scrollbar(
                              controller: _scrollController,
                              thumbVisibility: true,
                              interactive: true,
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  _horizontalReaderPadding,
                                  _topPadding,
                                  _horizontalReaderPadding,
                                  _bottomPadding,
                                ),
                                itemExtent: _lineExtent,
                                cacheExtent: _lineExtent * 60,
                                itemCount: currentLines.length,
                                itemBuilder: (context, index) {
                                  final line = currentLines[index];
                                  return Text(
                                    line.text,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    softWrap: false,
                                    style: _readerTextStyle,
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (!_fullScreen)
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(value: _lastProgress.clamp(0, 100) / 100),
                              ),
                              const SizedBox(width: 12),
                              Text('${_lastProgress.clamp(0, 100).toStringAsFixed(1)}%'),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}



class _Fb2ReaderScreen extends StatefulWidget {
  const _Fb2ReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_Fb2ReaderScreen> createState() => _Fb2ReaderScreenState();
}

class _Fb2ReaderScreenState extends State<_Fb2ReaderScreen> {
  // FB2 reader v2: the progress anchor is no longer derived from render boxes.
  // We build deterministic fixed-height render units, calculate offsets ourselves,
  // and save the first unit touching the top of the viewport. This repeats the
  // stable TXT approach while preserving FB2 images and links.
  static const _fontSize = 18.0;
  static const _heightFactor = 1.55;
  static const _lineExtent = _fontSize * _heightFactor;
  static const _titleExtent = 38.0;
  static const _imageExtent = 300.0;
  static const _horizontalReaderPadding = 22.0;
  static const _topPadding = 18.0;
  static const _bottomPadding = 28.0;
  static const _textStyle = TextStyle(fontSize: _fontSize, height: _heightFactor, color: Color(0xFF2F261F));
  static const _linkStyle = TextStyle(
    fontSize: _fontSize,
    height: _heightFactor,
    color: Color(0xFF7A4E1D),
    decoration: TextDecoration.underline,
  );

  final _scrollController = ScrollController();
  BookRecord? _runtimeBook;
  _Fb2Document? _document;
  List<_Fb2RenderUnit>? _units;
  List<double> _unitOffsets = const [];
  double _lastUsableWidth = 0;
  String? _loadError;
  Timer? _saveDebounce;
  Timer? _layoutDebounce;
  Timer? _progressRedrawThrottle;
  double _progress = 0;
  int _pendingUnitIndex = 0;
  bool _restoringPosition = false;
  bool _didInitialRestore = false;
  bool _fullScreen = false;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    _progress = widget.book.progressPercent;
    _scrollController.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _layoutDebounce?.cancel();
    _saveDebounce?.cancel();
    _progressRedrawThrottle?.cancel();
    final locator = _currentLocator();
    if (locator != null) unawaited(_saveProgress(locator));
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    var book = widget.book;
    for (final candidate in manifest.books) {
      if (candidate.id == widget.book.id) {
        book = candidate;
        break;
      }
    }
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл FB2 не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл FB2 отсутствует: ${book.localPath}');
      return;
    }
    try {
      final xml = _decodeTextFile(await file.readAsBytes());
      final document = _parseFb2Document(xml);
      if (!mounted) return;
      setState(() {
        _runtimeBook = book;
        _document = document;
        _loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = 'Не удалось открыть FB2: $error');
    }
  }

  void _ensureUnitsForWidth(double maxWidth) {
    final document = _document;
    if (document == null) return;
    final usableWidth = (maxWidth - (_horizontalReaderPadding * 2)).clamp(180.0, 2000.0).toDouble();
    if (_units != null && (usableWidth - _lastUsableWidth).abs() < 8) return;

    final current = _currentLocator()?.unitIndex ?? _pendingUnitIndex;
    _layoutDebounce?.cancel();
    _layoutDebounce = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) return;
      final built = _buildFb2RenderUnits(document, usableWidth);
      final units = built.isEmpty ? [_Fb2RenderUnit.text(const [_Fb2LineSegment('')], 0, false)] : built;
      final target = _targetUnitForBook(_book, units);
      setState(() {
        _units = units;
        _unitOffsets = _buildFb2UnitOffsets(units);
        _lastUsableWidth = usableWidth;
        _pendingUnitIndex = _didInitialRestore ? current.clamp(0, units.length - 1).toInt() : target;
        _progress = _Fb2UnitLocator(unitIndex: _pendingUnitIndex, unitCount: units.length).progressPercent;
      });
      _scheduleRestoreScroll();
    });
  }

  int _targetUnitForBook(BookRecord book, List<_Fb2RenderUnit> units) {
    if (units.isEmpty) return 0;
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map) {
        final type = decoded['type'];
        if (type == 'fb2-unit-anchor-v1') {
          return ((decoded['unitIndex'] as num?)?.round() ?? 0).clamp(0, units.length - 1).toInt();
        }
        if (type == 'fb2-block-anchor-v1') {
          final blockIndex = ((decoded['blockIndex'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
          final idx = units.indexWhere((unit) => unit.blockIndex >= blockIndex);
          return (idx < 0 ? units.length - 1 : idx).clamp(0, units.length - 1).toInt();
        }
        if (type == 'fb2-line-anchor-v1') {
          final lineIndex = ((decoded['lineIndex'] as num?)?.round() ?? 0).clamp(0, units.length - 1).toInt();
          return lineIndex;
        }
      }
    } catch (_) {}
    final progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
    return ((progress / 100.0) * (units.length - 1)).round().clamp(0, units.length - 1).toInt();
  }

  void _scheduleRestoreScroll() {
    final units = _units;
    if (units == null || units.isEmpty) return;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        for (var attempt = 0; attempt < 16; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 16 : 35));
          if (!mounted || !_scrollController.hasClients) continue;
          final target = _offsetForUnit(_pendingUnitIndex);
          _scrollController.jumpTo(target.clamp(0.0, _scrollController.position.maxScrollExtent));
          final locator = _currentLocator();
          _progress = locator?.progressPercent ?? _progress;
          _didInitialRestore = true;
          if (mounted) setState(() {});
          break;
        }
      } finally {
        _restoringPosition = false;
      }
    });
  }

  _Fb2UnitLocator? _currentLocator() {
    final units = _units;
    if (units == null || units.isEmpty) return null;
    if (!_scrollController.hasClients) {
      return _Fb2UnitLocator(unitIndex: _pendingUnitIndex.clamp(0, units.length - 1).toInt(), unitCount: units.length);
    }
    if (_scrollController.position.maxScrollExtent <= 0 || _scrollController.position.extentAfter <= 8) {
      return _Fb2UnitLocator(unitIndex: units.length - 1, unitCount: units.length);
    }
    final unitIndex = _unitIndexForOffset(_scrollController.offset).clamp(0, units.length - 1).toInt();
    return _Fb2UnitLocator(unitIndex: unitIndex, unitCount: units.length);
  }

  int _unitIndexForOffset(double offset) {
    final offsets = _unitOffsets;
    final units = _units;
    if (offsets.isEmpty || units == null || units.isEmpty) return 0;
    var lo = 0;
    var hi = offsets.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (offsets[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return hi.clamp(0, units.length - 1).toInt();
  }

  double _offsetForUnit(int unitIndex) {
    if (_unitOffsets.isEmpty) return 0;
    final safe = unitIndex.clamp(0, _unitOffsets.length - 1).toInt();
    return _unitOffsets[safe];
  }

  void _onScroll() {
    if (_restoringPosition || !_didInitialRestore || !_scrollController.hasClients) return;
    final locator = _currentLocator();
    if (locator == null) return;
    _progress = locator.progressPercent;
    if (!(_progressRedrawThrottle?.isActive ?? false)) {
      _progressRedrawThrottle = Timer(const Duration(milliseconds: 80), () {
        if (mounted) setState(() {});
      });
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_saveProgress(locator));
    });
  }

  Future<void> _saveProgress(_Fb2UnitLocator locator) async {
    final manifest = await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: locator.progressPercent,
      locator: locator.toJsonString(),
    );
    for (final book in manifest.books) {
      if (book.id == widget.book.id) {
        _runtimeBook = book;
        break;
      }
    }
    await widget.sync.broadcastLibrarySnapshot(reason: 'progress_updated');
  }

  Future<void> _addBookmark() async {
    final locator = _currentLocator();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: locator?.toJsonString() ?? _book.currentLocator,
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  Future<void> _copyImageDataUri(Uint8List bytes) async {
    final encoded = base64Encode(bytes);
    await Clipboard.setData(ClipboardData(text: 'data:image/*;base64,$encoded'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Изображение скопировано как data URI')));
  }

  Future<void> _openExternalLink(String href) async {
    final uri = Uri.tryParse(href.trim());
    if (uri == null || !uri.hasScheme) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Внутренняя ссылка: $href')));
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось открыть ссылку: $href')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final units = _units;
    return Scaffold(
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: units != null ? _addBookmark : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'fb2-bookmark-${widget.book.id}',
                  tooltip: 'Добавить закладку',
                  onPressed: units != null ? _addBookmark : null,
                  child: const Icon(Icons.bookmark_add_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fb2-exit-fullscreen-${widget.book.id}',
                  tooltip: 'Выйти из полного экрана',
                  onPressed: () => setState(() => _fullScreen = false),
                  child: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ],
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : document == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _ensureUnitsForWidth(constraints.maxWidth);
                          final currentUnits = _units;
                          if (currentUnits == null) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return SelectionArea(
                            child: Scrollbar(
                              controller: _scrollController,
                              thumbVisibility: true,
                              interactive: true,
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  _horizontalReaderPadding,
                                  _topPadding,
                                  _horizontalReaderPadding,
                                  _bottomPadding,
                                ),
                                cacheExtent: _lineExtent * 80,
                                itemCount: currentUnits.length,
                                itemBuilder: (context, index) {
                                  final unit = currentUnits[index];
                                  return SizedBox(
                                    height: unit.extent,
                                    child: _Fb2UnitView(
                                      unit: unit,
                                      onOpenLink: _openExternalLink,
                                      onCopyImage: _copyImageDataUri,
                                    ),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (!_fullScreen)
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                          child: Row(
                            children: [
                              Expanded(child: LinearProgressIndicator(value: _progress.clamp(0, 100) / 100)),
                              const SizedBox(width: 12),
                              Text('${_progress.clamp(0, 100).toStringAsFixed(1)}%'),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}


class _Fb2UnitView extends StatelessWidget {
  const _Fb2UnitView({required this.unit, required this.onOpenLink, required this.onCopyImage});

  final _Fb2RenderUnit unit;
  final ValueChanged<String> onOpenLink;
  final ValueChanged<Uint8List> onCopyImage;

  @override
  Widget build(BuildContext context) {
    if (unit.imageBytes != null) {
      final bytes = unit.imageBytes!;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Stack(
          children: [
            Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                height: _Fb2ReaderScreenState._imageExtent - 16,
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: IconButton.filledTonal(
                tooltip: 'Копировать изображение',
                onPressed: () => onCopyImage(bytes),
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ),
          ],
        ),
      );
    }

    final style = unit.isTitle
        ? const TextStyle(fontSize: 19, height: 1.45, fontWeight: FontWeight.w700, color: Color(0xFF2F261F))
        : _Fb2ReaderScreenState._textStyle;
    return Align(
      alignment: Alignment.centerLeft,
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.clip,
        softWrap: false,
        text: TextSpan(
          style: style,
          children: unit.segments.map((segment) {
            final href = segment.href;
            if (href == null || href.isEmpty) return TextSpan(text: segment.text);
            return TextSpan(
              text: segment.text,
              style: _Fb2ReaderScreenState._linkStyle,
              recognizer: TapGestureRecognizer()..onTap = () => onOpenLink(href),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _Fb2LineSegment {
  const _Fb2LineSegment(this.text, {this.href});
  final String text;
  final String? href;
}

class _Fb2RenderUnit {
  const _Fb2RenderUnit.text(this.segments, this.blockIndex, this.isTitle)
      : imageBytes = null,
        extent = isTitle ? _Fb2ReaderScreenState._titleExtent : _Fb2ReaderScreenState._lineExtent;

  const _Fb2RenderUnit.image(this.imageBytes, this.blockIndex)
      : segments = const [],
        isTitle = false,
        extent = _Fb2ReaderScreenState._imageExtent;

  final List<_Fb2LineSegment> segments;
  final Uint8List? imageBytes;
  final int blockIndex;
  final bool isTitle;
  final double extent;
}

class _Fb2UnitLocator {
  const _Fb2UnitLocator({required this.unitIndex, required this.unitCount});
  final int unitIndex;
  final int unitCount;

  double get progressPercent {
    if (unitCount <= 1) return unitCount == 1 && unitIndex > 0 ? 100 : 0;
    return ((unitIndex / (unitCount - 1)) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString() => jsonEncode({
        'type': 'fb2-unit-anchor-v1',
        'unitIndex': unitIndex,
        'unitCount': unitCount,
        'progressPercent': progressPercent,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
}

List<_Fb2RenderUnit> _buildFb2RenderUnits(_Fb2Document document, double usableWidth) {
  final units = <_Fb2RenderUnit>[];
  final charsPerLine = (usableWidth / (_Fb2ReaderScreenState._fontSize * 0.56)).floor().clamp(24, 140).toInt();
  for (var blockIndex = 0; blockIndex < document.blocks.length; blockIndex++) {
    final block = document.blocks[blockIndex];
    switch (block.kind) {
      case _Fb2BlockKind.image:
        final bytes = block.imageBytes;
        if (bytes != null && bytes.isNotEmpty) units.add(_Fb2RenderUnit.image(bytes, blockIndex));
        break;
      case _Fb2BlockKind.title:
        units.addAll(_wrapFb2Segments([_Fb2LineSegment(block.plainText)], blockIndex, true, charsPerLine));
        break;
      case _Fb2BlockKind.paragraph:
        final segments = block.inlines.map((inline) => _Fb2LineSegment(inline.text, href: inline.href)).toList();
        units.addAll(_wrapFb2Segments(segments, blockIndex, false, charsPerLine));
        break;
    }
  }
  return units;
}

List<_Fb2RenderUnit> _wrapFb2Segments(List<_Fb2LineSegment> source, int blockIndex, bool isTitle, int charsPerLine) {
  final result = <_Fb2RenderUnit>[];
  final current = <_Fb2LineSegment>[];
  var currentLen = 0;

  void flush() {
    if (current.isEmpty) return;
    final normalized = current.where((segment) => segment.text.isNotEmpty).toList();
    if (normalized.isNotEmpty) result.add(_Fb2RenderUnit.text(List.unmodifiable(normalized), blockIndex, isTitle));
    current.clear();
    currentLen = 0;
  }

  for (final segment in source) {
    var text = segment.text.replaceAll(RegExp(r'\s+'), ' ');
    while (text.isNotEmpty) {
      final remaining = charsPerLine - currentLen;
      if (remaining <= 0) {
        flush();
        continue;
      }
      if (text.length <= remaining) {
        current.add(_Fb2LineSegment(text, href: segment.href));
        currentLen += text.length;
        text = '';
      } else {
        var cut = text.lastIndexOf(' ', remaining);
        if (cut <= 0 || cut < remaining * 0.45) cut = remaining;
        final part = text.substring(0, cut).trimRight();
        if (part.isNotEmpty) {
          current.add(_Fb2LineSegment(part, href: segment.href));
          currentLen += part.length;
        }
        flush();
        text = text.substring(cut).trimLeft();
      }
    }
  }
  flush();
  return result;
}

List<double> _buildFb2UnitOffsets(List<_Fb2RenderUnit> units) {
  final offsets = <double>[];
  var offset = _Fb2ReaderScreenState._topPadding;
  for (final unit in units) {
    offsets.add(offset);
    offset += unit.extent;
  }
  return offsets;
}

enum _Fb2BlockKind { paragraph, title, image }

class _Fb2Inline {
  const _Fb2Inline(this.text, {this.href});
  final String text;
  final String? href;
}

class _Fb2Block {
  const _Fb2Block.paragraph(this.inlines)
      : kind = _Fb2BlockKind.paragraph,
        imageBytes = null,
        _titleText = '';
  const _Fb2Block.title(String text)
      : kind = _Fb2BlockKind.title,
        inlines = const [],
        imageBytes = null,
        _titleText = text;
  const _Fb2Block.image(this.imageBytes)
      : kind = _Fb2BlockKind.image,
        inlines = const [],
        _titleText = '';

  final _Fb2BlockKind kind;
  final List<_Fb2Inline> inlines;
  final Uint8List? imageBytes;
  final String _titleText;

  String get plainText => kind == _Fb2BlockKind.title ? _titleText : inlines.map((item) => item.text).join();
}

class _Fb2Document {
  const _Fb2Document(this.blocks);
  final List<_Fb2Block> blocks;
}

class _Fb2Locator {
  const _Fb2Locator({required this.blockIndex, required this.blockCount});
  final int blockIndex;
  final int blockCount;

  double get progressPercent {
    if (blockCount <= 1) return blockCount == 1 && blockIndex > 0 ? 100 : 0;
    return ((blockIndex / (blockCount - 1)) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString() => jsonEncode({
        'type': 'fb2-block-anchor-v1',
        'blockIndex': blockIndex,
        'blockCount': blockCount,
        'progressPercent': progressPercent,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
}

_Fb2Document _parseFb2Document(String xmlText) {
  final xml = _normalizeText(xmlText);
  final binaries = <String, Uint8List>{};
  final binaryRe = RegExp(r'<binary\b([^>]*)>(.*?)</binary>', caseSensitive: false, dotAll: true);
  for (final match in binaryRe.allMatches(xml)) {
    final attrs = match.group(1) ?? '';
    final id = _attr(attrs, 'id');
    if (id == null || id.isEmpty) continue;
    final payload = (match.group(2) ?? '').replaceAll(RegExp(r'\s+'), '');
    try {
      binaries[id] = Uint8List.fromList(base64Decode(payload));
    } catch (_) {}
  }

  var body = xml;
  final bodyMatch = RegExp(r'<body\b[^>]*>(.*?)</body>', caseSensitive: false, dotAll: true).firstMatch(xml);
  if (bodyMatch != null) body = bodyMatch.group(1) ?? body;
  body = body.replaceAll(RegExp(r'<binary\b[^>]*>.*?</binary>', caseSensitive: false, dotAll: true), '');
  body = body.replaceAll(RegExp(r'<description\b[^>]*>.*?</description>', caseSensitive: false, dotAll: true), '');
  body = body.replaceAll(RegExp(r'<empty-line\s*/?>', caseSensitive: false), '<p> </p>');

  final blocks = <_Fb2Block>[];
  final blockRe = RegExp(
    r'<image\b[^>]*/>|<title\b[^>]*>.*?</title>|<subtitle\b[^>]*>.*?</subtitle>|<p\b[^>]*>.*?</p>|<v\b[^>]*>.*?</v>',
    caseSensitive: false,
    dotAll: true,
  );
  for (final match in blockRe.allMatches(body)) {
    final raw = match.group(0) ?? '';
    if (raw.startsWith(RegExp(r'<image', caseSensitive: false))) {
      final href = _hrefFromTag(raw);
      final id = href?.replaceFirst('#', '');
      final image = id == null ? null : binaries[id];
      if (image != null) blocks.add(_Fb2Block.image(image));
      continue;
    }
    final isTitle = raw.startsWith(RegExp(r'<title|<subtitle', caseSensitive: false));
    if (isTitle) {
      final text = _stripFb2InlineTags(raw).trim();
      if (text.isNotEmpty) blocks.add(_Fb2Block.title(text));
      final images = RegExp(r'<image\b[^>]*/>', caseSensitive: false).allMatches(raw);
      for (final imageMatch in images) {
        final href = _hrefFromTag(imageMatch.group(0) ?? '');
        final id = href?.replaceFirst('#', '');
        final image = id == null ? null : binaries[id];
        if (image != null) blocks.add(_Fb2Block.image(image));
      }
      continue;
    }
    final images = RegExp(r'<image\b[^>]*/>', caseSensitive: false).allMatches(raw).toList();
    for (final imageMatch in images) {
      final href = _hrefFromTag(imageMatch.group(0) ?? '');
      final id = href?.replaceFirst('#', '');
      final image = id == null ? null : binaries[id];
      if (image != null) blocks.add(_Fb2Block.image(image));
    }
    final inlines = _parseFb2Inlines(raw);
    final text = inlines.map((item) => item.text).join().trim();
    if (text.isNotEmpty) blocks.add(_Fb2Block.paragraph(inlines));
  }

  if (blocks.isEmpty) {
    final text = _extractFb2Text(xml);
    for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
      final trimmed = paragraph.trim();
      if (trimmed.isNotEmpty) blocks.add(_Fb2Block.paragraph([_Fb2Inline(trimmed)]));
    }
  }
  return _Fb2Document(blocks.isEmpty ? [_Fb2Block.paragraph(const [_Fb2Inline('Не удалось извлечь содержимое FB2.')])] : blocks);
}

List<_Fb2Inline> _parseFb2Inlines(String rawBlock) {
  var content = rawBlock.replaceFirst(RegExp(r'^<[^>]+>', caseSensitive: false), '');
  content = content.replaceFirst(RegExp(r'</[^>]+>$', caseSensitive: false), '');
  content = content.replaceAll(RegExp(r'<image\b[^>]*/>', caseSensitive: false), '');
  final result = <_Fb2Inline>[];
  final linkRe = RegExp(r'<a\b([^>]*)>(.*?)</a>', caseSensitive: false, dotAll: true);
  var cursor = 0;
  for (final match in linkRe.allMatches(content)) {
    if (match.start > cursor) {
      final before = _stripFb2InlineTags(content.substring(cursor, match.start));
      if (before.isNotEmpty) result.add(_Fb2Inline(before));
    }
    final href = _hrefFromAttrs(match.group(1) ?? '');
    final linkText = _stripFb2InlineTags(match.group(2) ?? '');
    if (linkText.isNotEmpty) result.add(_Fb2Inline(linkText, href: href));
    cursor = match.end;
  }
  if (cursor < content.length) {
    final rest = _stripFb2InlineTags(content.substring(cursor));
    if (rest.isNotEmpty) result.add(_Fb2Inline(rest));
  }
  return result.isEmpty ? const [_Fb2Inline('')] : result;
}

String _stripFb2InlineTags(String input) {
  var text = input.replaceAll(RegExp(r'<[^>]+>', dotAll: true), '');
  text = _decodeXmlEntities(text);
  return text.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim();
}

String? _hrefFromTag(String tag) => _hrefFromAttrs(tag);

String? _hrefFromAttrs(String attrs) {
  return _attr(attrs, 'l:href') ?? _attr(attrs, 'xlink:href') ?? _attr(attrs, 'href');
}

String? _attr(String attrs, String name) {
  final escaped = RegExp.escape(name);
  final doubleQuoted = RegExp('$escaped\\s*=\\s*"([^"]*)"', caseSensitive: false, dotAll: true).firstMatch(attrs);
  if (doubleQuoted != null) return _decodeXmlEntities(doubleQuoted.group(1) ?? '').trim();
  final singleQuoted = RegExp("$escaped\\s*=\\s*'([^']*)'", caseSensitive: false, dotAll: true).firstMatch(attrs);
  return singleQuoted == null ? null : _decodeXmlEntities(singleQuoted.group(1) ?? '').trim();
}

class _PdfReaderScreen extends StatefulWidget {
  const _PdfReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<_PdfReaderScreen> {
  PdfController? _controller;
  BookRecord? _runtimeBook;
  int _page = 1;
  int _pages = 0;
  String? _loadError;
  Timer? _saveDebounce;
  bool _fullScreen = false;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    var book = widget.book;
    for (final candidate in manifest.books) {
      if (candidate.id == widget.book.id) {
        book = candidate;
        break;
      }
    }
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл PDF не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл PDF отсутствует: ${book.localPath}');
      return;
    }
    final initialPage = _targetPageForBook(book);
    final controller = PdfController(
      document: PdfDocument.openFile(file.path),
      initialPage: initialPage,
    );
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _runtimeBook = book;
      _page = initialPage;
      _controller = controller;
      _loadError = null;
    });
  }

  int _targetPageForBook(BookRecord book) {
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map && decoded['type'] == 'pdf-page-v1') {
        final page = ((decoded['page'] as num?)?.round() ?? 1).clamp(1, 100000).toInt();
        return page;
      }
    } catch (_) {}
    final p = book.progressPercent.clamp(0, 100).toDouble();
    if (p <= 0) return 1;
    return ((p / 100.0) * 1000).round().clamp(1, 100000).toInt();
  }

  void _onDocumentLoaded(PdfDocument document) {
    final pages = document.pagesCount;
    final safePage = _page.clamp(1, pages).toInt();
    setState(() {
      _pages = pages;
      _page = safePage;
    });
    if (safePage != _controller?.page) {
      _controller?.jumpToPage(safePage);
    }
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_savePage(page));
    });
  }

  Future<void> _savePage(int page) async {
    final pages = _pages > 0 ? _pages : (_controller?.pagesCount ?? 0);
    final progress = pages <= 1 ? 0.0 : (((page - 1) / (pages - 1)) * 100).clamp(0.0, 100.0).toDouble();
    final locator = jsonEncode({
      'type': 'pdf-page-v1',
      'page': page,
      'pages': pages,
      'progressPercent': progress,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await widget.storage.updateProgress(bookId: widget.book.id, progressPercent: progress, locator: locator);
    await widget.sync.broadcastLibrarySnapshot(reason: 'pdf_progress_updated');
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? FloatingActionButton.small(
              heroTag: 'pdf-exit-fullscreen-${widget.book.id}',
              tooltip: 'Выйти из полного экрана',
              onPressed: () => setState(() => _fullScreen = false),
              child: const Icon(Icons.fullscreen_exit_rounded),
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : controller == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: PdfView(
                        controller: controller,
                        scrollDirection: Axis.vertical,
                        pageSnapping: false,
                        onDocumentLoaded: _onDocumentLoaded,
                        onPageChanged: _onPageChanged,
                      ),
                    ),
                    if (!_fullScreen)
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: _pages <= 1 ? 0 : ((_page - 1) / (_pages - 1)).clamp(0.0, 1.0).toDouble(),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(_pages > 0 ? '$_page / $_pages' : '$_page'),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _TextLine {
  const _TextLine({required this.text, required this.startChar, required this.endChar});

  final String text;
  final int startChar;
  final int endChar;
}

class _TextAnchorLocator {
  const _TextAnchorLocator({
    required this.anchorChar,
    required this.totalChars,
    required this.lineIndex,
    required this.lineCount,
    this.scrollOffset,
    this.maxScrollExtent,
    this.viewportWidth,
  });

  final int anchorChar;
  final int totalChars;
  final int lineIndex;
  final int lineCount;
  final double? scrollOffset;
  final double? maxScrollExtent;
  final double? viewportWidth;

  double get progressPercent {
    if (totalChars <= 0) return 0;
    return ((anchorChar / totalChars) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString({String type = 'txt-line-anchor-v1'}) => jsonEncode({
        'type': type,
        'anchorChar': anchorChar,
        'totalChars': totalChars,
        'lineIndex': lineIndex,
        'lineCount': lineCount,
        if (scrollOffset != null) 'scrollOffset': scrollOffset,
        if (maxScrollExtent != null) 'maxScrollExtent': maxScrollExtent,
        if (viewportWidth != null) 'viewportWidth': viewportWidth,
        'progressPercent': progressPercent,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
}

int _lineIndexForChar(List<_TextLine> lines, int charIndex) {
  if (lines.isEmpty) return 0;
  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final mid = low + ((high - low) >> 1);
    final line = lines[mid];
    if (charIndex < line.startChar) {
      high = mid - 1;
    } else if (charIndex >= line.endChar) {
      low = mid + 1;
    } else {
      return mid;
    }
  }
  return low.clamp(0, lines.length - 1).toInt();
}

List<_TextLine> _buildDisplayLines(String text, double usableWidth) {
  final normalized = _normalizeText(text);
  if (normalized.isEmpty) return const [];
  final averageCharWidth = _fontWidthEstimate(_TxtReaderScreenState._fontSize);
  final maxCharsPerLine = (usableWidth / averageCharWidth).floor().clamp(24, 140).toInt();
  final result = <_TextLine>[];
  var globalStart = 0;
  final sourceLines = normalized.split('\n');
  for (var sourceIndex = 0; sourceIndex < sourceLines.length; sourceIndex++) {
    final sourceLine = sourceLines[sourceIndex];
    if (sourceLine.isEmpty) {
      result.add(_TextLine(text: '', startChar: globalStart, endChar: globalStart));
      globalStart += sourceIndex == sourceLines.length - 1 ? 0 : 1;
      continue;
    }

    var localStart = 0;
    while (localStart < sourceLine.length) {
      var localEnd = (localStart + maxCharsPerLine).clamp(localStart + 1, sourceLine.length).toInt();
      if (localEnd < sourceLine.length) {
        final window = sourceLine.substring(localStart, localEnd);
        final splitAt = window.lastIndexOf(RegExp(r'[ \t\u00A0]'));
        final minUseful = (maxCharsPerLine * 0.55).round();
        if (splitAt > minUseful) {
          localEnd = localStart + splitAt + 1;
        }
      }
      final display = sourceLine.substring(localStart, localEnd).trimRight();
      result.add(_TextLine(
        text: display,
        startChar: globalStart + localStart,
        endChar: globalStart + localEnd,
      ));
      localStart = localEnd;
      while (localStart < sourceLine.length && sourceLine.codeUnitAt(localStart) == 0x20) {
        localStart += 1;
      }
    }
    globalStart += sourceLine.length;
    if (sourceIndex != sourceLines.length - 1) globalStart += 1;
  }
  return result;
}

double _fontWidthEstimate(double fontSize) => fontSize * 0.56;

String _decodeTextFile(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeWindows1251(bytes);
  }
}

String _normalizeText(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _extractFb2Text(String xmlText) {
  var text = _normalizeText(xmlText);
  text = text.replaceAll(RegExp(r'<\?xml[^>]*>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<binary\b[^>]*>.*?</binary>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<description\b[^>]*>.*?</description>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<empty-line\s*/?>', caseSensitive: false), '\n\n');
  text = text.replaceAll(RegExp(r'</(p|v|subtitle|title|section|poem|stanza)>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<(p|v|subtitle|title)\b[^>]*>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<[^>]+>', dotAll: true), '');
  text = _decodeXmlEntities(text);
  text = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trimRight())
      .join('\n');
  text = text.replaceAll(RegExp(r'\n{4,}'), '\n\n\n').trim();
  return text.isEmpty ? 'Не удалось извлечь текст из FB2.' : text;
}

String _decodeXmlEntities(String text) {
  return text.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (match) {
    final entity = match.group(1)!;
    switch (entity) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return ' ';
    }
    if (entity.startsWith('#x') || entity.startsWith('#X')) {
      final value = int.tryParse(entity.substring(2), radix: 16);
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    if (entity.startsWith('#')) {
      final value = int.tryParse(entity.substring(1));
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    return match.group(0)!;
  });
}

String _decodeWindows1251(List<int> bytes) {
  const table = <int>[
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x0000, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
    0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
    0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
    0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
    0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
    0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
    0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
    0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
  ];

  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0x80) {
      buffer.writeCharCode(byte);
    } else {
      final codePoint = table[byte - 0x80];
      buffer.writeCharCode(codePoint == 0 ? 0xFFFD : codePoint);
    }
  }
  return buffer.toString();
}

class _UnsupportedReaderPlaceholder extends StatelessWidget {
  const _UnsupportedReaderPlaceholder({required this.book});

  final BookRecord book;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.extension_rounded, size: 56),
            const SizedBox(height: 16),
            Text(
              'Формат ${book.format.toUpperCase()} добавлен в библиотеку, но renderer еще не подключен в MVP.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Production-версия должна подключить Readium/MuPDF/DjVuLibre/DOCX adapter и сохранять locator для каждого формата.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.storage,
    required this.sync,
  });

  final StorageService storage;
  final SyncService sync;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _relayController = TextEditingController();
  final _personalHubRelayController = TextEditingController();
  final _accountController = TextEditingController();
  final _deviceNameController = TextEditingController();
  final _pairingInputController = TextEditingController();
  LibraryManifest? _manifest;
  SyncSettings? _settings;
  RelayEndpointMode _endpointMode = RelayEndpointMode.custom;
  bool _busy = false;
  bool _healthBusy = false;
  bool _pairingBusy = false;
  bool _logExpanded = false;
  PairingInvite? _pairingInvite;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _relayController.dispose();
    _personalHubRelayController.dispose();
    _accountController.dispose();
    _deviceNameController.dispose();
    _pairingInputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    final settings = await widget.storage.loadSyncSettings();
    if (!mounted) return;
    _manifest = manifest;
    _settings = settings;
    _endpointMode = settings.endpointMode;
    _relayController.text = settings.customRelayUrl;
    _personalHubRelayController.text = settings.personalHubRelayUrl;
    _accountController.text = manifest.accountId;
    _deviceNameController.text = manifest.deviceName;
    setState(() {});
  }

  SyncSettings _settingsFromForm({bool? autoConnect}) => SyncSettings(
        endpointMode: _endpointMode,
        customRelayUrl: _relayController.text.trim(),
        personalHubRelayUrl: _personalHubRelayController.text.trim(),
        autoConnect: autoConnect ?? _settings?.autoConnect ?? false,
      );

  Future<void> _saveIdentity() async {
    setState(() => _busy = true);
    try {
      await widget.sync.disconnect();
      var manifest = await widget.storage.changeAccountId(_accountController.text);
      manifest = await widget.storage.changeDeviceName(_deviceNameController.text);
      if (!mounted) return;
      setState(() => _manifest = manifest);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Идентификатор аккаунта и имя устройства сохранены')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      if (settings.usesOfficialPlaceholder) {
        throw StateError(
          'Официальный relay ещё не настроен в этой сборке. Выберите “Свой relay”, “Personal Hub” или соберите приложение с READANYWHERE_DEFAULT_RELAY_URL.',
        );
      }
      if (settings.usesPersonalHubPlaceholder) {
        throw StateError(
          'Для Personal Hub вставьте реальный Funnel/Tunnel URL, например https://your-device.your-tailnet.ts.net.',
        );
      }
      await widget.storage.saveSyncSettings(settings);
      await widget.sync.connect(relayUrl: settings.effectiveRelayUrl);
      _settings = await widget.storage.loadSyncSettings();
      _manifest = await widget.storage.loadManifest();
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось подключиться: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await widget.sync.disconnect();
    final settings = await widget.storage.loadSyncSettings();
    await widget.storage.saveSyncSettings(settings.copyWith(autoConnect: false));
    if (!mounted) return;
    setState(() => _settings = settings.copyWith(autoConnect: false));
  }

  Future<void> _checkRelayHealth() async {
    setState(() => _healthBusy = true);
    final settings = _settingsFromForm();
    try {
      if (settings.usesOfficialPlaceholder) {
        throw StateError('Официальный relay ещё не настроен в этой сборке.');
      }
      if (settings.usesPersonalHubPlaceholder) {
        throw StateError('Укажите реальный URL Personal Hub/Funnel.');
      }
      final base = Uri.parse(settings.effectiveRelayUrl);
      final healthUri = base.replace(
        scheme: base.scheme == 'ws'
            ? 'http'
            : base.scheme == 'wss'
                ? 'https'
                : base.scheme,
        path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/health'.replaceAll('//health', '/health'),
        query: '',
      );
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(healthUri);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response.statusCode >= 200 && response.statusCode < 300
                ? 'Relay доступен: HTTP ${response.statusCode}'
                : 'Relay ответил с ошибкой HTTP ${response.statusCode}: $body',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Relay недоступен: $error')),
      );
    } finally {
      if (mounted) setState(() => _healthBusy = false);
    }
  }

  Future<void> _createPairingInvite() async {
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: _settings?.autoConnect ?? false);
      await widget.storage.saveSyncSettings(settings);
      final invite = await widget.sync.createPairingInvite(settings: settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _pairingInvite = invite;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код подключения создан')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать код: $error')),
      );
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<PairingInvite?> _ensurePairingInvite() async {
    if (_pairingInvite != null) return _pairingInvite;
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: _settings?.autoConnect ?? false);
      await widget.storage.saveSyncSettings(settings);
      final invite = await widget.sync.createPairingInvite(settings: settings);
      if (!mounted) return invite;
      setState(() {
        _settings = settings;
        _pairingInvite = invite;
      });
      return invite;
    } catch (error) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать QR-код: $error')),
      );
      return null;
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _showPairingQrCode() async {
    final invite = await _ensurePairingInvite();
    if (!mounted || invite == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR-код подключения'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: invite.inviteLink,
              version: QrVersions.auto,
              size: 260,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            Text('Устройство: ${invite.ownerDeviceName}'),
            const SizedBox(height: 4),
            Text('Код: ${invite.displayCode}'),
            const SizedBox(height: 4),
            Text(
              'Отсканируйте QR-код на новом устройстве в ReadAnywhere.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanPairingQrCode() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сканирование QR-кода доступно на мобильных устройствах.')),
      );
      return;
    }
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _PairingQrScannerScreen()),
    );
    if (scanned == null || scanned.trim().isEmpty || !mounted) return;
    _pairingInputController.text = scanned.trim();
    await _claimPairingInvite();
  }

  Future<void> _claimPairingInvite() async {
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      final result = await widget.sync.claimPairingInvite(
        input: _pairingInputController.text,
        fallbackSettings: settings,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Подключено к аккаунту ${result.ownerDeviceName}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось подключиться по коду: $error')),
      );
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _copyPairingInvite() async {
    final invite = _pairingInvite;
    if (invite == null) return;
    await Clipboard.setData(ClipboardData(text: invite.inviteLink));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Приглашение скопировано')),
    );
  }

  Future<void> _sendSnapshot() async {
    final sent = await widget.sync.broadcastLibrarySnapshot(reason: 'manual');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? 'Snapshot отправлен' : 'Сначала подключитесь к relay')),
    );
  }

  Future<void> _requestSnapshot() async {
    await widget.sync.refreshMetadata(reason: 'manual');
    final sent = true;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? 'Snapshot запрошен' : 'Сначала подключитесь к relay')),
    );
  }

  Future<void> _copyAccountId() async {
    await Clipboard.setData(ClipboardData(text: _accountController.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('accountId скопирован')),
    );
  }


  Future<void> _removeTrustedDevice(TrustedDeviceRecord device) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить устройство?'),
        content: Text(
          'Устройство «${device.name}» будет скрыто из списка доверенных. Если оно подключится заново через QR-код/код, запись появится снова.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await widget.storage.removeTrustedDevice(device.deviceId);
      await widget.sync.broadcastLibrarySnapshot(reason: 'trusted_device_removed');
      if (!mounted) return;
      setState(() => _manifest = updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить устройство: $error')),
      );
    }
  }

  Future<void> _pruneTrustedDevices() async {
    try {
      final updated = await widget.storage.pruneDeletedTrustedDevices();
      if (!mounted) return;
      setState(() => _manifest = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список устройств очищен')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось очистить список: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    if (manifest == null || _settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final hiddenTrustedDevices = manifest.trustedDevices.where((device) => device.isDeleted).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ValueListenableBuilder<SyncStateSnapshot>(
        valueListenable: widget.sync.state,
        builder: (context, syncState, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _SectionCard(
                title: 'Статус',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(syncState.statusText),
                    const SizedBox(height: 8),
                    SelectableText('accountId: ${manifest.accountId}'),
                    Text('device: ${manifest.deviceName}'),
                    const SizedBox(height: 8),
                    Text('Отправлено событий: ${syncState.sentEvents}'),
                    Text('Получено событий: ${syncState.receivedEvents}'),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Relay endpoint',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Обычно пользователь не должен вводить IP-адрес. Сейчас можно использовать Personal Hub через Tailscale Funnel/Cloudflare Tunnel, локальный relay для разработки или свой relay. В продуктовой сборке официальный endpoint задается через dart-define.',
                    ),
                    const SizedBox(height: 12),
                    _RelayModeOption(
                      value: RelayEndpointMode.official,
                      groupValue: _endpointMode,
                      title: 'ReadAnywhere relay',
                      subtitle: ReadAnywhereRelayConfig.officialRelayUrl,
                      onChanged: (value) => setState(() => _endpointMode = value),
                    ),
                    _RelayModeOption(
                      value: RelayEndpointMode.personalHub,
                      groupValue: _endpointMode,
                      title: 'Personal Hub / Tailscale Funnel',
                      subtitle: 'Relay запущен на вашем устройстве и опубликован через Funnel/Tunnel',
                      onChanged: (value) => setState(() => _endpointMode = value),
                    ),
                    if (_endpointMode == RelayEndpointMode.personalHub) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _personalHubRelayController,
                        decoration: const InputDecoration(
                          labelText: 'Personal Hub URL',
                          helperText: 'Например: https://your-device.your-tailnet.ts.net',
                        ),
                      ),
                    ],
                    _RelayModeOption(
                      value: RelayEndpointMode.custom,
                      groupValue: _endpointMode,
                      title: 'Свой relay',
                      subtitle: 'VPS, Cloudflare Tunnel, домашний сервер, другой WebSocket relay',
                      onChanged: (value) => setState(() => _endpointMode = value),
                    ),
                    if (_endpointMode == RelayEndpointMode.custom) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _relayController,
                        decoration: const InputDecoration(
                          labelText: 'Custom Relay URL',
                          helperText: 'Например: https://relay.example.com или http://192.168.1.10:8787',
                        ),
                      ),
                    ],
                    _RelayModeOption(
                      value: RelayEndpointMode.localDevelopment,
                      groupValue: _endpointMode,
                      title: 'Локальная разработка',
                      subtitle: ReadAnywhereRelayConfig.localDevelopmentRelayUrl,
                      onChanged: (value) => setState(() => _endpointMode = value),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Текущий endpoint: ${SyncSettings(endpointMode: _endpointMode, customRelayUrl: _relayController.text, personalHubRelayUrl: _personalHubRelayController.text).effectiveRelayUrl}',
                    ),
                    Text("Автоподключение: ${_settings?.autoConnect == true ? 'включено' : 'выключено'}"),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _healthBusy ? null : _checkRelayHealth,
                      icon: _healthBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.health_and_safety_outlined),
                      label: const Text('Проверить relay'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _connect,
                            icon: const Icon(Icons.link_rounded),
                            label: const Text('Подключиться'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _disconnect,
                            icon: const Icon(Icons.link_off_rounded),
                            label: const Text('Отключиться'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _sendSnapshot,
                      icon: const Icon(Icons.upload_rounded),
                      label: const Text('Отправить snapshot библиотеки'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _requestSnapshot,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Запросить snapshot у других устройств'),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Подключение устройства',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Теперь accountId не нужно копировать вручную. На первом устройстве создайте код, на новом устройстве введите код или вставьте приглашение.',
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _pairingBusy ? null : _createPairingInvite,
                            icon: _pairingBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.add_link_rounded),
                            label: const Text('Создать код подключения'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pairingBusy ? null : _showPairingQrCode,
                            icon: const Icon(Icons.qr_code_2_rounded),
                            label: const Text('Создать QR-код'),
                          ),
                        ),
                      ],
                    ),
                    if (_pairingInvite != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Theme.of(context).colorScheme.primaryContainer,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Устройство: ${_pairingInvite!.ownerDeviceName}'),
                            const SizedBox(height: 6),
                            Text(
                              _pairingInvite!.displayCode,
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text('Действует до: ${_pairingInvite!.expiresAt.toLocal()}'),
                            const SizedBox(height: 8),
                            SelectableText('Relay: ${_pairingInvite!.relayUrl}'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _copyPairingInvite,
                              icon: const Icon(Icons.copy_rounded),
                              label: const Text('Скопировать приглашение'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const Divider(height: 32),
                    TextField(
                      controller: _pairingInputController,
                      decoration: const InputDecoration(
                        labelText: 'Код или приглашение',
                        helperText: 'Например: 483-921 или readanywhere://pair?...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _pairingBusy ? null : _claimPairingInvite,
                            icon: const Icon(Icons.login_rounded),
                            label: const Text('Подключиться по коду'),
                          ),
                        ),
                        if (Platform.isAndroid || Platform.isIOS) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pairingBusy ? null : _scanPairingQrCode,
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              label: const Text('Сканировать QR'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Доверенные устройства',
                child: manifest.activeTrustedDevices.isEmpty
                    ? const Text('Пока только текущее устройство')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Удалённые устройства скрываются из списка и синхронизируются как отозванные. Текущее устройство удалить нельзя.${hiddenTrustedDevices > 0 ? ' Скрытых записей: $hiddenTrustedDevices.' : ''}',
                          ),
                          const SizedBox(height: 8),
                          ...manifest.activeTrustedDevices.map((device) {
                            final isCurrent = device.deviceId == manifest.deviceId;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(isCurrent ? Icons.phone_iphone_rounded : Icons.devices_rounded),
                              title: Text('${device.name}${isCurrent ? ' • это устройство' : ''}'),
                              subtitle: Text('${device.role} • ${device.deviceId}'),
                              trailing: isCurrent
                                  ? null
                                  : IconButton(
                                      tooltip: 'Удалить устройство из списка',
                                      icon: const Icon(Icons.delete_outline_rounded),
                                      onPressed: () => _removeTrustedDevice(device),
                                    ),
                            );
                          }),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _pruneTrustedDevices,
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Очистить скрытые записи'),
                          ),
                        ],
                      ),
              ),
              _SectionCard(
                title: 'Дополнительно: ручной accountId',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                      ),
                      child: const Text(
                        'Ручной accountId оставлен только как fallback для разработки. В обычном сценарии используйте подключение по коду выше.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _accountController,
                      decoration: const InputDecoration(labelText: 'accountId'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _deviceNameController,
                      decoration: const InputDecoration(labelText: 'Название устройства'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _saveIdentity,
                            icon: const Icon(Icons.save_rounded),
                            label: const Text('Сохранить'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _copyAccountId,
                            icon: const Icon(Icons.copy_rounded),
                            label: const Text('Скопировать'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText('deviceId: ${manifest.deviceId}'),
                  ],
                ),
              ),
              Card(
                child: ExpansionTile(
                  initiallyExpanded: _logExpanded,
                  onExpansionChanged: (value) => setState(() => _logExpanded = value),
                  title: const Text('Журнал событий'),
                  subtitle: Text(syncState.logLines.isEmpty
                      ? 'Пока нет событий'
                      : 'Событий: ${syncState.logLines.length}'),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    if (syncState.logLines.isEmpty)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Пока нет событий'),
                      )
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: syncState.logLines.map(Text.new).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


class _PairingQrScannerScreen extends StatefulWidget {
  const _PairingQrScannerScreen();

  @override
  State<_PairingQrScannerScreen> createState() => _PairingQrScannerScreenState();
}

class _PairingQrScannerScreenState extends State<_PairingQrScannerScreen> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать QR-код')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                if (_handled) return;
                final barcodes = capture.barcodes;
                if (barcodes.isEmpty) return;
                final value = barcodes.first.rawValue;
                if (value == null || value.trim().isEmpty) return;
                _handled = true;
                Navigator.of(context).pop(value.trim());
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Наведите камеру на QR-код подключения ReadAnywhere.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RelayModeOption extends StatelessWidget {
  const _RelayModeOption({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  final RelayEndpointMode value;
  final RelayEndpointMode groupValue;
  final String title;
  final String subtitle;
  final ValueChanged<RelayEndpointMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<RelayEndpointMode>(
      contentPadding: EdgeInsets.zero,
      value: value,
      groupValue: groupValue,
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
