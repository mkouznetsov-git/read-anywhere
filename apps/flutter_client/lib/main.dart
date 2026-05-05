import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    final started = await widget.sync.requestBookFile(book);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started
              ? 'Запросили файл у других устройств'
              : 'Не удалось начать скачивание. Проверьте подключение к relay.',
        ),
      ),
    );
  }

  Future<void> _cancelBookDownload(BookRecord book) async {
    await widget.sync.cancelBookFileDownload(book.id);
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.books ?? [];

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
                          currentDeviceId: manifest.deviceId,
                          transfer: transfer,
                          onDownload: !book.isDownloaded && transfer?.active != true
                              ? () => _downloadBook(book)
                              : null,
                          onCancelDownload: transfer?.active == true
                              ? () => _cancelBookDownload(book)
                              : null,
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
    required this.currentDeviceId,
    required this.onOpen,
    required this.onDownload,
    required this.onCancelDownload,
    required this.transfer,
  });

  final BookRecord book;
  final String currentDeviceId;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onCancelDownload;
  final FileTransferSnapshot? transfer;

  @override
  Widget build(BuildContext context) {
    final remoteCount = book.availableOnDeviceIds
        .where((deviceId) => deviceId != currentDeviceId)
        .length;
    final statusText = book.isDownloaded
        ? 'Скачана на этом устройстве'
        : remoteCount > 0
            ? 'Не скачана здесь • доступна на $remoteCount устройстве(ах)'
            : 'Только в библиотеке';
    final progress = book.progressPercent.clamp(0, 100).toStringAsFixed(1);
    final transfer = this.transfer;
    final isDownloading = transfer?.active == true;
    final hasDownloadError = transfer?.hasError == true;

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${book.format.toUpperCase()} • $statusText'),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(value: book.progressPercent / 100),
              ),
              const SizedBox(height: 4),
              Text('Прогресс чтения: $progress%'),
              if (transfer != null) ...[
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
                      ? '${transfer.statusText}: ${transfer.error}'
                      : transfer.statusText,
                ),
              ],
            ],
          ),
        ),
        trailing: isDownloading
            ? IconButton(
                tooltip: 'Отменить скачивание',
                onPressed: onCancelDownload,
                icon: const Icon(Icons.cancel_outlined),
              )
            : IconButton(
                tooltip: book.isDownloaded ? 'Читать' : 'Скачать на это устройство',
                onPressed: book.isDownloaded ? onOpen : onDownload,
                icon: Icon(book.isDownloaded
                    ? Icons.menu_book_rounded
                    : Icons.cloud_download_outlined),
              ),
      ),
    );
  }
}

class ReaderScreen extends StatefulWidget {
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
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  // Reader position must be content-based, not pixel-scroll based.
  // TXT pages are rebuilt from the text and current viewport size using
  // TextPainter pagination, while the saved locator stores an anchor character index. This lets macOS/Android
  // return to the same text fragment even when their screens differ.
  static const _minLogicalPageChars = 220;
  static const _maxLogicalPageChars = 2200;
  static const _readerTextStyle = TextStyle(fontSize: 18, height: 1.65);

  final _pageController = PageController();
  List<_TextChunk>? _textPages;
  String? _rawText;
  String? _pageLayoutSignature;
  int _totalChars = 0;
  int _pendingRestoreChar = 0;
  bool _restoreScheduled = false;
  String? _loadError;
  Timer? _saveDebounce;
  double _lastProgress = 0;
  int _currentPageIndex = 0;
  bool _restoringPosition = false;
  BookRecord? _runtimeBook;
  _TextPageLocator? _lastKnownLocator;

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
    _load();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    final locator = _currentPageLocator() ?? _lastKnownLocator;
    if (locator != null) {
      // Best-effort flush so closing the reader does not lose the last page.
      unawaited(_saveProgress(locator));
    }
    _pageController.dispose();
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
    if (book.format != 'txt') {
      setState(() => _textPages = null);
      return;
    }

    try {
      final file = File(book.localPath!);
      if (!await file.exists()) {
        throw StateError('Файл отсутствует: ${book.localPath}');
      }
      final bytes = await file.readAsBytes();
      final raw = _normalizeText(_decodeTextFile(bytes));
      final totalChars = raw.length;
      final targetChar = _targetCharForBook(book, totalChars);

      if (!mounted) return;
      setState(() {
        _rawText = raw;
        _textPages = null;
        _pageLayoutSignature = null;
        _totalChars = totalChars;
        _pendingRestoreChar = targetChar;
        _currentPageIndex = 0;
        _lastKnownLocator = null;
        _lastProgress = totalChars <= 0
            ? 0
            : ((targetChar / totalChars) * 100).clamp(0.0, 100.0).toDouble();
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = 'Не удалось открыть TXT: $error');
    }
  }

  void _scheduleRestorePage(int targetPage) {
    final pages = _textPages;
    if (pages == null || pages.isEmpty || _restoreScheduled) return;
    _restoreScheduled = true;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        for (var attempt = 0; attempt < 12; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 16 : 45));
          if (!mounted) return;
          if (_pageController.hasClients) {
            final safeTarget = targetPage.clamp(0, pages.length - 1).toInt();
            _pageController.jumpToPage(safeTarget);
            _currentPageIndex = safeTarget;
            _lastKnownLocator = _locatorForPage(pages, safeTarget, _totalChars);
            _lastProgress = _lastKnownLocator!.progressPercent;
            if (mounted) setState(() {});
            break;
          }
        }
      } finally {
        _restoringPosition = false;
        _restoreScheduled = false;
      }
    });
  }

  List<_TextChunk> _pagesForConstraints(BoxConstraints constraints) {
    final raw = _rawText ?? '';
    final viewportWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 420.0;
    final viewportHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 640.0;

    // Keep this in sync with the Padding around page content in itemBuilder.
    const horizontalPadding = 48.0;
    const verticalPadding = 42.0;
    final contentWidth = (viewportWidth - horizontalPadding).clamp(220.0, 1600.0).toDouble();
    final contentHeight = (viewportHeight - verticalPadding).clamp(260.0, 1400.0).toDouble();
    final signature =
        '${contentWidth.round()}x${contentHeight.round()}:${raw.length}:txt-page-v3';

    if (_textPages != null && _pageLayoutSignature == signature) {
      return _textPages!;
    }

    final pages = raw.isEmpty
        ? [_TextChunk(text: '', startChar: 0, endChar: 0)]
        : _paginateTextForViewport(raw, contentWidth, contentHeight, _readerTextStyle);
    final safePages = pages.isEmpty
        ? [_TextChunk(text: '', startChar: 0, endChar: 0)]
        : pages;
    final targetPage = _chunkIndexForChar(safePages, _pendingRestoreChar);
    final locator = _locatorForPage(safePages, targetPage, _totalChars);

    _textPages = safePages;
    _pageLayoutSignature = signature;
    _currentPageIndex = targetPage;
    _lastKnownLocator = locator;
    _lastProgress = locator.progressPercent;
    _scheduleRestorePage(targetPage);

    return safePages;
  }

  List<_TextChunk> _paginateTextForViewport(
    String text,
    double contentWidth,
    double contentHeight,
    TextStyle style,
  ) {
    final normalized = _normalizeText(text);
    if (normalized.isEmpty) return const [];

    final pages = <_TextChunk>[];
    var start = 0;

    while (start < normalized.length) {
      final remaining = normalized.length - start;
      final hardHigh = start + remaining.clamp(_minLogicalPageChars, _maxLogicalPageChars).toInt();
      var low = start + 1;
      var high = hardHigh.clamp(start + 1, normalized.length).toInt();
      var best = low;

      // Binary-search the longest substring that fits into the visible page.
      while (low <= high) {
        final mid = low + ((high - low) >> 1);
        if (_textFitsPage(normalized.substring(start, mid), contentWidth, contentHeight, style)) {
          best = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }

      // Prefer clean page breaks, but never skip text and never create a tiny page.
      final minUsefulEnd = start + ((best - start) * 0.65).floor();
      var end = best;
      if (best < normalized.length) {
        final paragraphBreak = normalized.lastIndexOf('\n\n', best);
        final lineBreak = normalized.lastIndexOf('\n', best);
        final spaceBreak = normalized.lastIndexOf(' ', best);
        if (paragraphBreak > minUsefulEnd) {
          end = paragraphBreak + 2;
        } else if (lineBreak > minUsefulEnd) {
          end = lineBreak + 1;
        } else if (spaceBreak > minUsefulEnd) {
          end = spaceBreak + 1;
        }
      }

      // Safety fallback for very long unbreakable fragments.
      if (end <= start) {
        end = (start + _minLogicalPageChars).clamp(start + 1, normalized.length).toInt();
      }

      pages.add(_TextChunk(
        text: normalized.substring(start, end),
        startChar: start,
        endChar: end,
      ));
      start = end;
    }

    return pages;
  }

  bool _textFitsPage(
    String text,
    double maxWidth,
    double maxHeight,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return painter.height <= maxHeight;
  }

  int _targetCharForBook(BookRecord book, int totalChars) {
    if (totalChars <= 0) return 0;

    final decoded = _tryDecodeLocatorJson(book.currentLocator);
    if (decoded != null) {
      final type = decoded['type'];
      if (type == 'txt-page-v3' || type == 'txt-page-v2') {
        final anchorChar = ((decoded['anchorChar'] as num?)?.round() ??
                (decoded['startChar'] as num?)?.round() ??
                0)
            .clamp(0, totalChars)
            .toInt();
        return anchorChar;
      }
      if (type == 'txt-page-v1') {
        final startChar = (decoded['startChar'] as num?)?.round();
        if (startChar != null) return startChar.clamp(0, totalChars).toInt();
        final oldPageIndex = ((decoded['pageIndex'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        final oldPageCount = ((decoded['pageCount'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        if (oldPageCount > 0) {
          return ((oldPageIndex / oldPageCount) * totalChars).round().clamp(0, totalChars).toInt();
        }
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
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // Old locators such as txt-scroll:... are intentionally ignored; the
      // stored progress percent is a safer fallback for them.
    }
    return null;
  }

  int _pageIndexFromProgress(double progressPercent, int pageCount) {
    if (pageCount <= 1) return 0;
    final progress = progressPercent.clamp(0.0, 100.0).toDouble();
    if (progress <= 0) return 0;
    // Progress is displayed as currentPage / totalPages. For example, 5% in a
    // 100-page book means page 5, which is zero-based index 4.
    final oneBasedPage = (progress / 100.0 * pageCount).ceil();
    return (oneBasedPage - 1).clamp(0, pageCount - 1).toInt();
  }

  _TextPageLocator? _currentPageLocator() {
    final pages = _textPages;
    if (pages == null || pages.isEmpty) return null;
    final index = _currentPageIndex.clamp(0, pages.length - 1).toInt();
    return _locatorForPage(pages, index, _totalChars);
  }

  _TextPageLocator _locatorForPage(List<_TextChunk> pages, int pageIndex, int totalChars) {
    final safeIndex = pageIndex.clamp(0, pages.length - 1).toInt();
    final page = pages[safeIndex];
    return _TextPageLocator(
      pageIndex: safeIndex,
      pageCount: pages.length,
      startChar: page.startChar,
      endChar: page.endChar,
      totalChars: totalChars,
    );
  }

  void _onPageChanged(int index) {
    if (_restoringPosition) return;
    final pages = _textPages;
    if (pages == null || pages.isEmpty) return;
    final safeIndex = index.clamp(0, pages.length - 1).toInt();
    final locator = _locatorForPage(pages, safeIndex, _totalChars);
    _currentPageIndex = safeIndex;
    _lastKnownLocator = locator;
    _lastProgress = locator.progressPercent;
    if (mounted) setState(() {});
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_saveProgress(locator));
    });
  }

  Future<void> _saveProgress(_TextPageLocator locator) async {
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
    final locator = _currentPageLocator();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: locator?.toJsonString() ?? _book.currentLocator,
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Закладка добавлена')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTxt = _book.format == 'txt';
    final rawText = _rawText;
    return Scaffold(
      appBar: AppBar(
        title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Добавить закладку',
            onPressed: isTxt && rawText != null ? _addBookmark : null,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
        ],
      ),
      body: !isTxt
          ? _UnsupportedReaderPlaceholder(book: _book)
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(_loadError!, textAlign: TextAlign.center),
                  ),
                )
              : rawText == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final pages = _pagesForConstraints(constraints);
                        return Column(
                          children: [
                            Expanded(
                              child: PageView.builder(
                                controller: _pageController,
                                scrollDirection: Axis.vertical,
                                onPageChanged: _onPageChanged,
                                itemCount: pages.length,
                                itemBuilder: (context, index) {
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
                                    child: Align(
                                      alignment: Alignment.topLeft,
                                      child: Text(
                                        pages[index].text,
                                        softWrap: true,
                                        overflow: TextOverflow.clip,
                                        style: _readerTextStyle,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: LinearProgressIndicator(value: _lastProgress / 100),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      '${_lastProgress.toStringAsFixed(1)}% · '
                                      'стр. ${_currentPageIndex + 1}/${pages.length}',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
    );
  }
}

class _TextChunk {
  const _TextChunk({
    required this.text,
    required this.startChar,
    required this.endChar,
  });

  final String text;
  final int startChar;
  final int endChar;

  int get length => endChar - startChar;
}

class _TextPageLocator {
  const _TextPageLocator({
    required this.pageIndex,
    required this.pageCount,
    required this.startChar,
    required this.endChar,
    required this.totalChars,
  });

  final int pageIndex;
  final int pageCount;
  final int startChar;
  final int endChar;
  final int totalChars;

  double get progressPercent {
    if (totalChars <= 0) return 0;
    if (pageCount > 0 && pageIndex >= pageCount - 1) return 100;
    return ((startChar / totalChars) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString() => jsonEncode({
        'type': 'txt-page-v3',
        'pageIndex': pageIndex,
        'pageCount': pageCount,
        'anchorChar': startChar,
        'startChar': startChar,
        'endChar': endChar,
        'totalChars': totalChars,
        'progressPercent': progressPercent,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
}

int _chunkIndexForChar(List<_TextChunk> chunks, int charIndex) {
  if (chunks.isEmpty) return 0;
  var low = 0;
  var high = chunks.length - 1;
  while (low <= high) {
    final mid = low + ((high - low) >> 1);
    final chunk = chunks[mid];
    if (charIndex < chunk.startChar) {
      high = mid - 1;
    } else if (charIndex >= chunk.endChar) {
      low = mid + 1;
    } else {
      return mid;
    }
  }
  return low.clamp(0, chunks.length - 1).toInt();
}

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

List<_TextChunk> _splitTextIntoReaderChunks(String text, int targetChars) {
  final normalized = _normalizeText(text);
  if (normalized.isEmpty) return const [];

  final chunks = <_TextChunk>[];
  var start = 0;
  while (start < normalized.length) {
    var end = start + targetChars;
    if (end >= normalized.length) {
      end = normalized.length;
    } else {
      final paragraphBreak = normalized.lastIndexOf('\n\n', end);
      final lineBreak = normalized.lastIndexOf('\n', end);
      final minUsefulSplit = start + (targetChars ~/ 2);
      if (paragraphBreak > minUsefulSplit) {
        end = paragraphBreak + 2;
      } else if (lineBreak > minUsefulSplit) {
        end = lineBreak + 1;
      }
    }

    var chunkText = normalized.substring(start, end);
    final trimmedRight = chunkText.trimRight();
    final trimmedEnd = start + trimmedRight.length;
    if (trimmedRight.isNotEmpty) {
      chunks.add(_TextChunk(
        text: trimmedRight,
        startChar: start,
        endChar: trimmedEnd,
      ));
    }
    start = end;
  }
  return chunks;
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

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    if (manifest == null || _settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
                    FilledButton.icon(
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
                    FilledButton.icon(
                      onPressed: _pairingBusy ? null : _claimPairingInvite,
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Подключиться по коду'),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Доверенные устройства',
                child: manifest.trustedDevices.isEmpty
                    ? const Text('Пока только текущее устройство')
                    : Column(
                        children: manifest.trustedDevices.map((device) {
                          final isCurrent = device.deviceId == manifest.deviceId;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(isCurrent ? Icons.phone_iphone_rounded : Icons.devices_rounded),
                            title: Text('${device.name}${isCurrent ? ' • это устройство' : ''}'),
                            subtitle: Text('${device.role} • ${device.deviceId}'),
                          );
                        }).toList(),
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
              _SectionCard(
                title: 'Журнал',
                child: syncState.logLines.isEmpty
                    ? const Text('Пока нет событий')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: syncState.logLines.map(Text.new).toList(),
                      ),
              ),
            ],
          );
        },
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
