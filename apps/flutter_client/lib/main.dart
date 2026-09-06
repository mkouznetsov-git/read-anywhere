Warning: truncated output (original token count: 82629)
Total output lines: 8665

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:pdfx/pdfx.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/book.dart';
import 'models/manifest.dart';
import 'models/sync_settings.dart';
import 'services/book_import_service.dart';
import 'services/format_engines/djvu_embedded_engine.dart';
import 'services/format_engines/djvu_embedded_probe.dart';
import 'services/storage_service.dart';
import 'services/sync/sync_service.dart';
import 'ui/app_theme.dart';

bool get _isDesktopReaderPlatform => Platform.isMacOS || Platform.isLinux || Platform.isWindows;
bool get _isAndroidReaderPlatform => Platform.isAndroid;

const Color _raIndigoCard = Color(0xFF302849);
const Color _raWarmGold = Color(0xFFC9AA78);
const Color _raPaper = Color(0xFFF3E7CF);
const Color _raInkBlue = Color(0xFF2A2F4A);
const Color _raMutedPaper = Color(0xFFCFC5B5);
const Color _raFaintIndigo = Color(0xFF4A405F);

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('ReadArc Flutter error: ${details.exceptionAsString()}\n${details.stack}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('ReadArc uncaught platform error: $error\n$stack');
        return true;
      };
      runApp(const ReadArcApp());
    },
    (error, stack) {
      debugPrint('ReadArc uncaught zone error: $error\n$stack');
    },
  );
}

class ReadArcApp extends StatefulWidget {
  const ReadArcApp({super.key, this.autoConnect = true, this.storage, this.sync, this.disposeSync = true})
    : assert(sync == null || storage != null);

  final bool autoConnect;
  final StorageService? storage;
  final SyncService? sync;
  final bool disposeSync;

  @override
  State<ReadArcApp> createState() => _ReadArcAppState();
}

class _ReadArcAppState extends State<ReadArcApp> {
  late final _storage = widget.storage ?? StorageService();
  late final _sync = widget.sync ?? SyncService(_storage);

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) unawaited(_autoConnectSync());
  }

  Future<void> _autoConnectSync() async {
    try {
      final settings = await _storage.loadSyncSettings();
      if (!settings.autoConnect) return;
      if (settings.usesOfficialPlaceholder) return;
      await _sync.connect(relayUrl: settings.effectiveRelayUrl);
    } catch (error) {
      debugPrint('ReadArc auto-connect failed: $error');
      final settings = await _storage.loadSyncSettings();
      if (settings.autoConnect && !settings.usesOfficialPlaceholder) {
        _sync.startAutoReconnect(relayUrl: settings.effectiveRelayUrl);
      }
    }
  }

  @override
  void dispose() {
    if (widget.disposeSync) unawaited(_sync.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ReadArc',
      theme: ReadArcTheme.light(),
      home: LibraryScreen(storage: _storage, sync: _sync),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.storage, required this.sync});

  final StorageService storage;
  final SyncService sync;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _importService = BookImportService(widget.storage);
  LibraryManifest? _manifest;
  bool _busy = false;
  bool _bulkDownloadBusy = false;
  String? _libraryLoadError;
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
    try {
      final manifest = await widget.storage.loadManifest().timeout(const Duration(seconds: 12));
      if (mounted) {
        setState(() {
          _manifest = manifest;
          _libraryLoadError = null;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('ReadArc manifest load failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _libraryLoadError = 'Не удалось загрузить библиотеку: $error');
    }
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось добавить книгу: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadBook(BookRecord book) async {
    if (!widget.sync.state.value.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет подключения к relay.')));
      return;
    }

    final started = await widget.sync.requestBookFile(book);
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Не удалось начать скачивание. Проверьте подключение к relay.')));
    }
  }

  Future<void> _downloadWholeLibrary(List<BookRecord> books) async {
    final toDownload = books.where((book) => !book.isDownloaded && !book.isDeleted).toList();
    if (toDownload.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Все книги уже скачаны на это устройство.')));
      return;
    }
    if (!widget.sync.state.value.connected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет подключения к relay.')));
      return;
    }
    final totalBytes = toDownload.fold<int>(0, (sum, book) => sum + book.sizeBytes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Скачать всю библиотеку?'),
        content: Text(
          'Скачать всю библиотеку (${_formatUiBytes(totalBytes)}) на это устройство?\n\n'
          'Будет загружено книг: ${toDownload.length}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Нет')),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Да, скачать'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _bulkDownloadBusy = true);
    var started = 0;
    var completed = 0;
    try {
      for (final book in toDownload) {
        if (!mounted) break;
        final currentManifest = await widget.storage.loadManifest();
        BookRecord? currentBook;
        for (final candidate in currentManifest.books) {
          if (candidate.id == book.id) {
            currentBook = candidate;
            break;
          }
        }
        if (currentBook?.isDownloaded == true) {
          completed += 1;
          continue;
        }
        final ok = await widget.sync.requestBookFile(currentBook ?? book);
        if (ok) {
          started += 1;
          final done = await _waitForBookDownloaded(book.id, timeout: const Duration(minutes: 10));
          if (done) completed += 1;
        }
        await _reload();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Скачивание библиотеки: завершено $completed, запущено $started.')));
    } finally {
      if (mounted) setState(() => _bulkDownloadBusy = false);
    }
  }

  Future<bool> _waitForBookDownloaded(String bookId, {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final manifest = await widget.storage.loadManifest();
      for (final book in manifest.books) {
        if (book.id == bookId) {
          if (book.isDownloaded) return true;
          final transfer = widget.sync.state.value.downloadForBook(bookId);
          if (transfer != null && transfer.hasError && transfer.active == false) return false;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<void> _cancelBookDownload(BookRecord book) async {
    await widget.sync.cancelBookFileDownload(book.id);
  }

  Future<void> _removeLocalCopy(BookRecord book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить с устройства?'),
        content: Text(
          'Книга «${book.title}» останется в библиотеке аккаунта, но файл будет удалён с этого устройства. Позже её можно будет скачать снова с другого устройства.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить файл')),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось удалить файл: $error')));
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
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить из библиотеки')),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось удалить книгу: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.visibleBooks ?? [];

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/brand/readarc_icon_128.png'),
          ),
        ),
        title: const Text('ReadArc'),
        actions: [
          ValueListenableBuilder<SyncStateSnapshot>(
            valueListenable: widget.sync.state,
            builder: (context, syncState, _) {
              final hasRemoteBooks = books.any((book) => !book.isDownloaded && !book.isDeleted);
              return IconButton(
                tooltip: syncState.connected
                    ? 'Скачать всю библиотеку на устройство'
                    : 'Скачивание недоступно: relay не подключен',
                onPressed: (!syncState.connected || _bulkDownloadBusy || !hasRemoteBooks)
                    ? null
                    : () => _downloadWholeLibrary(books),
                icon: _bulkDownloadBusy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_for_offline_outlined),
              );
            },
          ),
          ValueListenableBuilder<SyncStateSnapshot>(
            valueListenable: widget.sync.state,
            builder: (context, syncState, _) {
              return IconButton(
                tooltip: syncState.connected ? 'Синхронизация подключена' : 'Синхронизация',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SyncScreen(storage: widget.storage, sync: widget.sync),
                    ),
                  );
                  await _reload();
                },
                icon: Icon(syncState.connected ? Icons.sync_rounded : Icons.sync_disabled_rounded),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addBook,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_rounded),
        label: const Text('Добавить книгу'),
      ),
      body: _libraryLoadError != null && manifest == null
          ? _LibraryLoadErrorView(message: _libraryLoadError!, onRetry: _reload)
          : manifest == null
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
                      onDownload: syncState.connected && !book.isDownloaded && transfer?.active != true
                          ? () => _downloadBook(book)
                          : null,
                      onCancelDownload: transfer?.active == true ? () => _cancelBookDownload(book) : null,
                      onRemoveLocalCopy: book.isDownloaded ? () => _removeLocalCopy(book) : null,
                      onDeleteFromLibrary: () => _deleteFromLibrary(book),
                      onOpen: book.isDownloaded
                          ? () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ReaderScreen(book: book, storage: widget.storage, sync: widget.sync),
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

String _formatUiBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _LibraryLoadErrorView extends StatelessWidget {
  const _LibraryLoadErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42, color: _raWarmGold),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _raMutedPaper),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => unawaited(onRetry()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
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
    final transfer = this.transfer;
    final isDownloading = transfer?.active == true;
    final hasDownloadError = transfer?.hasError == true;
    final showTransfer = transfer != null && !book.isDownloaded && (isDownloading || hasDownloadError);
    final format = book.format.toUpperCase();
    final sizeText = _formatUiBytes(book.sizeBytes);
    final progressText = '${book.progressPercent.clamp(0, 100).toStringAsFixed(0)}%';

    return Card(
      color: _raIndigoCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: _raWarmGold.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: book.isDownloaded ? onOpen : onDownload,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: _raPaper, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  _LibraryMetaChip(label: format),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('•', style: TextStyle(color: _raMutedPaper, fontSize: 11)),
                  ),
                  _LibraryMetaChip(label: sizeText),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Tooltip(
                      message: 'Прочитано $progressText',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progressValue,
                          minHeight: 4,
                          valueColor: const AlwaysStoppedAnimation<Color>(_raWarmGold),
                          backgroundColor: _raFaintIndigo.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 42,
                    child: Text(
                      progressText,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(color: _raMutedPaper, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isDownloading)
                    IconButton(
                      tooltip: 'Отменить скачивание',
                      visualDensity: VisualDensity.compact,
                      color: _raWarmGold,
                      onPressed: onCancelDownload,
                      icon: const Icon(Icons.cancel_outlined),
                    )
                  else
                    TextButton.icon(
                      onPressed: book.isDownloaded ? onOpen : onDownload,
                      icon: Icon(book.isDownloaded ? Icons.menu_book_rounded : Icons.cloud_download_outlined, size: 17),
                      label: Text(book.isDownloaded ? 'Читать' : 'Скачать'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: _raWarmGold,
                        backgroundColor: _raWarmGold.withValues(alpha: 0.12),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                    ),
                  PopupMenuButton<_BookAction>(
                    tooltip: 'Действия с книгой',
                    iconColor: _raWarmGold,
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
                        const PopupMenuItem(value: _BookAction.removeLocalCopy, child: Text('Удалить с устройства')),
                      const PopupMenuItem(value: _BookAction.deleteFromLibrary, child: Text('Удалить из библиотеки')),
                    ],
                  ),
                ],
              ),
              if (showTransfer) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: transfer.progressPercent.clamp(0, 100) / 100, minHeight: 4),
                ),
                const SizedBox(height: 4),
                Text(
                  hasDownloadError ? (transfer.error ?? 'Ошибка скачивания') : transfer.statusText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryMetaChip extends StatelessWidget {
  const _LibraryMetaChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: _raMutedPaper),
    );
  }
}

enum _BookAction { removeLocalCopy, deleteFromLibrary }

class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key, required this.book, required this.storage, required this.sync});

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
      case 'epub':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync, sourceKind: _RichSourceKind.epub);
      case 'docx':
        return _DocxReaderScreen(book: book, storage: storage, sync: sync);
      case 'doc':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync, sourceKind: _RichSourceKind.doc);
      case 'chm':
        return _ChmSafeReaderScreen(book: book, storage: storage, sync: sync);
      case 'djvu':
      case 'djv':
        return _DjvuReaderScreen(book: book, storage: storage, sync: sync);
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

class _TxtReaderScreen extends StatefulWidget {
  const _TxtReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

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
  static const _readerTextStyle = TextStyle(fontSize: _fontSize, height: _heightFactor, color: Color(0xFF2A2F4A));
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
  bool _textProgressScrubActive = false;

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
      final raw = _normalizeText(_decodeTextFile(bytes));
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
      setState(() => _loadError = 'Не удалось открыть TXT: $error');
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
          type == 'epub-line-anchor-v1' ||
          type == 'docx-line-anchor-v1' ||
          type == 'doc-line-anchor-v1' ||
          type == 'chm-line-anchor-v1' ||
          type == 'djvu-line-anchor-v1' ||
          type == 'txt-top-anchor-v3' ||
          type == 'txt-top-anchor-v2' ||
          type == 'txt-top-anchor-v1' ||
          type == 'txt-anchor-v1') {
        return ((decoded['anchorChar'] as num?)?.round() ?? 0).clamp(0, totalChars).toInt();
      }
      if (type == 'txt-page-v3' || type == 'txt-page-v2') {
        return ((decoded['anchorChar'] as num?)?.round() ?? (decoded['startChar'] as num?)?.round() ?? 0)
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
    _saveDebounce = Timer(const Duration(milliseconds: 1100), () {
      unawaited(_saveProgress(locator));
    });
  }

  void _scheduleProgressRedraw() {
    if (_progressRedrawThrottle?.isActive ?? false) return;
    _progressRedrawThrottle = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() {});
    });
  }

  void _setTextProgressFromFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * fraction.clamp(0.0, 1.0))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
    final locator = _currentLocator();
    if (locator != null) {
      _lastKnownLocator = locator;
      _lastProgress = locator.progressPercent;
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 450), () => unawaited(_saveProgress(locator)));
    }
    if (mounted) setState(() {});
  }

  void _deactivateTextProgressScrub() {
    if (_textProgressScrubActive) setState(() => _textProgressScrubActive = false);
  }

  String get _textLocatorType => 'txt-line-anchor-v1';

  String get _textReaderLabel => 'TXT';

  Future<void> _copyVisibleText() async {
    final lines = _lines;
    if (lines == null || lines.isEmpty) return;
    final current = _currentLocator();
    final start = (current?.lineIndex ?? 0).clamp(0, lines.length - 1).toInt();
    final end = (start + 36).clamp(start + 1, lines.length).toInt();
    final text = lines.sublist(start, end).map((line) => line.text).join('\n').trimRight();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Скопирован фрагмент $_textReaderLabel (${end - start} строк)')));
  }

  Future<void> _saveProgress(_TextAnchorLocator locator) async {
    final manifest = await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: locator.progressPercent,
      locator: locator.toJsonString(type: _textLocatorType),
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
      locator: locator?.toJsonString(type: _textLocatorType) ?? _book.currentLocator,
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
      backgroundColor: const Color(0xFFF3E7CF),
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
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: lines != null ? _copyVisibleText : null,
                  icon: const Icon(Icons.copy_all_rounded),
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
                  heroTag: 'txt-copy-${widget.book.id}',
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: lines != null ? _copyVisibleText : null,
                  child: const Icon(Icons.copy_all_rounded),
                ),
                const SizedBox(height: 8),
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
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _deactivateTextProgressScrub,
                        child: SelectionArea(
                          child: Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            interactive: true,
                            child: ListView.builder(
                              scrollCacheExtent: const ScrollCacheExtent.pixels(_lineExtent * 60),
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(
                                _horizontalReaderPadding,
                                _topPadding,
                                _horizontalReaderPadding,
                                _bottomPadding,
                              ),
                              itemExtent: _lineExtent,
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
                        ),
                      );
                    },
                  ),
                ),
                if (!_fullScreen)
                  _ContinuousReaderProgressBar(
                    progress: (_lastProgress.clamp(0, 100) / 100).toDouble(),
                    label: '${_lastProgress.clamp(0, 100).toStringAsFixed(1)}%',
                    active: _textProgressScrubActive,
                    onActivate: () => setState(() => _textProgressScrubActive = true),
                    onFractionSelected: _setTextProgressFromFraction,
                  ),
              ],
            ),
    );
  }
}

class _DocxReaderScreen extends StatefulWidget {
  const _DocxReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_DocxReaderScreen> createState() => _DocxReaderScreenState();
}

class _DocxReaderScreenState extends State<_DocxReaderScreen> {
  final _scrollController = ScrollController();
  BookRecord? _runtimeBook;
  _Fb2Document? _document;
  String? _loadError;
  bool _fullScreen = false;
  bool _docxProgressScrubActive = false;
  bool _restoring = false;
  Timer? _saveDebounce;
  Timer? _redrawThrottle;
  double _progress = 0;

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
    _saveDebounce?.cancel();
    _redrawThrottle?.cancel();
    if (_document != null) {
      final progress = _currentProgress();
      unawaited(_saveProgress(progress));
    }
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
    const label = 'DOCX';
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл $label не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл $label отсутствует: ${book.localPath}');
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      final document = _parseRichDocumentFromBytes(_RichSourceKind.docx, bytes);
      if (!mounted) return;
      setState(() {
        _runtimeBook = book;
        _document = document;
        _progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
        _loadError = null;
      });
      _restoreScroll(_targetProgressForBook(book));
    } catch (error) {
      if (mounted) setState(() => _loadError = 'Не удалось открыть $label: $error');
    }
  }

  double _targetProgressForBook(BookRecord book) {
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map && (decoded['type'] == _officeLocatorType || decoded['type'] == 'docx-rich-scroll-v1')) {
        return ((decoded['progressPercent'] as num?)?.toDouble() ?? book.progressPercent).clamp(0.0, 100.0).toDouble();
      }
    } catch (_) {}
    return book.progressPercent.clamp(0.0, 100.0).toDouble();
  }

  void _restoreScroll(double progress) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) return;
      _restoring = true;
      try {
        for (var attempt = 0; attempt < 20; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 24 : 40));
          if (!mounted || !_scrollController.hasClients) continue;
          final max = _scrollController.position.maxScrollExtent;
          if (max <= 0 && attempt < 8) continue;
          _scrollController.jumpTo((max * (progress / 100.0)).clamp(0.0, max));
          break;
        }
      } finally {
        _restoring = false;
      }
    });
  }

  double _currentProgress() {
    if (!_scrollController.hasClients) return _progress;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return 0;
    return ((position.pixels / position.maxScrollExtent) * 100).clamp(0.0, 100.0).toDouble();
  }

  void _setDocxProgressFromFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * fraction.clamp(0.0, 1.0))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
    final progress = _currentProgress();
    _progress = progress;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () => unawaited(_saveProgress(progress)));
    if (mounted) setState(() {});
  }

  void _deactivateDocxProgressScrub() {
    if (_docxProgressScrubActive) setState(() => _docxProgressScrubActive = false);
  }

  void _onScroll() {
    if (_restoring || !_scrollController.hasClients) return;
    final progress = _currentProgress();
    _progress = progress;
    if (!(_redrawThrottle?.isActive ?? false)) {
      _redrawThrottle = Timer(const Duration(milliseconds: 90), () {
        if (mounted) setState(() {});
      });
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveProgress(progress));
    });
  }

  String get _officeLocatorType => 'docx-rich-scroll-v1';

  String _locatorJson(double progress) => jsonEncode({
    'type': _officeLocatorType,
    'progressPercent': progress.clamp(0.0, 100.0),
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });

  Future<void> _saveProgress(double progress) async {
    await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: progress.clamp(0.0, 100.0).toDouble(),
      locator: _locatorJson(progress),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'docx_progress_updated');
  }

  Future<void> _copyAll() async {
    final doc = _document;
    if (doc == null) return;
    final text = [...doc.officeHeaderBlocks, ...doc.blocks, ...doc.officeFooterBlocks]
        .map((block) => block.plainText)
        .where((line) => line.trim().isNotEmpty && line != _officePageBreakMarker)
        .join('\n\n');
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Текст DOCX скопирован')));
  }

  Future<void> _addBookmark() async {
    final progress = _currentProgress();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка DOCX ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: _locatorJson(progress),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Скопировать текст документа',
                  onPressed: document == null ? null : _copyAll,
                  icon: const Icon(Icons.copy_all_rounded),
                ),
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: document == null ? null : _addBookmark,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? FloatingActionButton.small(
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
          : document == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xFFE7D7B9),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _deactivateDocxProgressScrub,
                      child: Builder(
                        builder: (context) {
                          final reader = Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            interactive: !Platform.isAndroid && !Platform.isIOS,
                            child: ListView(
                              scrollCacheExtent: const ScrollCacheExtent.pixels(3600),
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(14, 18, 14, 32),
                              children: [_DocxPageView(document: document)],
                            ),
                          );
                          // Android/iOS selection over a scaled Office page can trigger platform-specific
                          // layout/paint failures. Keep the document visible on mobile and preserve
                          // desktop text selection; mobile still has the toolbar "copy all" action.
                          return _selectionAreaIsCheapForRichReader() ? SelectionArea(child: reader) : reader;
                        },
                      ),
                    ),
                  ),
                ),
                if (!_fullScreen)
                  _ContinuousReaderProgressBar(
                    progress: (_progress.clamp(0, 100) / 100).toDouble(),
                    label: '${_progress.clamp(0, 100).toStringAsFixed(1)}%',
                    active: _docxProgressScrubActive,
                    onActivate: () => setState(() => _docxProgressScrubActive = true),
                    onFractionSelected: _setDocxProgressFromFraction,
                  ),
              ],
            ),
    );
  }
}

class _DocxPageView extends StatelessWidget {
  const _DocxPageView({required this.document});

  final _Fb2Document document;

  List<_Fb2Block> _visibleBlocks() {
    // Keep explicit page-break markers in the flow. Earlier builds filtered them
    // out here, so the paginator ignored Word-declared page breaks and then
    // guessed page starts from rough height estimates.
    final result = document.blocks.toList(growable: false);
    if (result.any((block) => block.plainText.trim().isNotEmpty && block.plainText != _officePageBreakMarker)) {
      return result;
    }
    return const [
      _Fb2Block.paragraph([_Fb2Inline('DOCX открыт, но в документе не найдено отображаемое содержимое.')]),
    ];
  }

  List<List<_Fb2Block>> _buildPages() {
    final page = document.officePageFormat;
    final logicalBodyHeight = (page.logicalPageHeight - page.logicalTopMargin - page.logicalBottomMargin)
        .clamp(360.0, 1600.0)
        .toDouble();
    final headerReserve = document.officeHeaderBlocks.isEmpty ? 0.0 : 42.0;
    // Reserve a real footer band. A DOCX footer is not part of body flow: if the
    // paginator lets body blocks consume this band, text visually sticks to the
    // signature/footer line at the bottom of the page.
    final footerReserve = document.officeFooterBlocks.isEmpty ? 0.0 : 18.0;
    final usableHeight = (logicalBodyHeight - headerReserve - footerReserve + 44.0)
        .clamp(300.0, logicalBodyHeight)
        .toDouble();
    final usableWidth = (page.logicalPageWidth - page.logicalLeftMargin - page.logicalRightMargin)
        .clamp(260.0, 1400.0)
        .toDouble();

    final pages = <List<_Fb2Block>>[];
    var current = <_Fb2Block>[];
    var cursor = 0.0;

    void flush() {
      if (current.isEmpty) return;
      final hasVisibleContent = current.any((block) {
        if (block.kind == _Fb2BlockKind.image || block.kind == _Fb2BlockKind.table) return true;
        final text = block.plainText.replaceAll(_officePageBreakMarker, '').trim();
        return text.isNotEmpty;
      });
      // Keep intentional blank paragraphs inside a real page, but never create a
      // whole empty DOCX page from a run of section/page-break artifacts.
      if (hasVisibleContent) pages.add(List.unmodifiable(current));
      current = <_Fb2Block>[];
      cursor = 0.0;
    }

    for (final block in _visibleBlocks()) {
      if (block.plainText == _officePageBreakMarker) {
        flush();
        continue;
      }
      final estimate = _estimateDocxBlockHeight(block, usableWidth).clamp(12.0, usableHeight).toDouble();
      if (current.isNotEmpty && cursor + estimate > usableHeight) {
        flush();
      }
      current.add(block);
      cursor += estimate;
    }
    flush();
    if (pages.isEmpty) pages.add(_visibleBlocks());
    return pages;
  }

  double _estimateDocxBlockHeight(_Fb2Block block, double usableWidth) {
    switch (block.kind) {
      case _Fb2BlockKind.image:
        return 260;
      case _Fb2BlockKind.table:
        final rowCount = block.tableRows.length.clamp(1, 200).toInt();
        final maxCell = block.tableRows
            .expand((row) => row)
            .fold<int>(0, (max, cell) => cell.length > max ? cell.length : max);
        final extraLines = (maxCell / 42).ceil().clamp(0, 4).toInt();
        return 10.0 + rowCount * (16.0 + extraLines * 6.0);
      case _Fb2BlockKind.title:
      case _Fb2BlockKind.paragraph:
        final text = block.plainText.trim();
        final format = block.officeFormat;
        final fontSize = (format.fontSize <= 0 ? 11.0 : format.fontSize).clamp(8.0, 28.0).toDouble();
        final charsPerLine = (usableWidth / (fontSize * 0.48)).clamp(18.0, 120.0).toDouble();
        final hardLines = text.split('\n');
        var lines = 0;
        for (final line in hardLines) {
          final len = line.trimRight().isEmpty ? 1 : line.trimRight().length;
          lines += (len / charsPerL…52629 tokens truncated… = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (hex.length.isOdd) hex += '0';
  final bytes = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    final value = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (value != null) bytes.add(value);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final codes = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codes.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(codes);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final codes = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codes.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codes);
  }
  return latin1.decode(bytes, allowInvalid: true).replaceAll('\x00', '');
}

String _normalizeExtractedPdfText(String text) {
  final lines = _normalizeText(text)
      .replaceAll('\x00', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim())
      .where((line) => line.length >= 2)
      .toList(growable: false);
  final deduped = <String>[];
  String? previous;
  for (final line in lines) {
    if (line == previous) continue;
    previous = line;
    deduped.add(line);
  }
  return deduped.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
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
      result.add(_TextLine(text: display, startChar: globalStart + localStart, endChar: globalStart + localEnd));
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
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeWindows1251(bytes);
  }
}

String _normalizeText(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _safeUnsupportedBinaryPreview(String formatLabel) {
  return '$formatLabel-файл сохранён и синхронизируется как оригинал. Чтобы не показывать бинарные “кракозябры”, ReadArc не открывает этот формат как сырой текст. Для полноценного просмотра нужен нативный адаптер/конвертер формата.';
}

String _extractChmText(Uint8List bytes) {
  // CHM is an ITSF container; most real books/help files store topics compressed
  // with LZX. A naive binary string scan produces readable-looking mojibake, so
  // this adapter only shows high-confidence HTML/TOC fragments. Otherwise it
  // deliberately falls back to a clear message instead of “кракозябры”.
  final candidates = <String>[];

  void addCandidate(String text) {
    final normalized = _normalizeText(text)
        .replaceAll('\x00', '')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim())
        .where(_looksReadableChmLine)
        .toList(growable: false);
    candidates.addAll(normalized);
  }

  final cp1251 = _decodeWindows1251(bytes);
  final utf8Text = utf8.decode(bytes, allowMalformed: true);
  final utf16Text = _extractUtf16LeRuns(bytes, minLength: 8);

  for (final source in [cp1251, utf8Text, utf16Text]) {
    for (final html in RegExp(
      r'<(?:html|body|h[1-6]|p|li|ul|ol|table|tr|td|object)\b[^>]*>.*?(?:</(?:html|body|h[1-6]|p|li|ul|ol|table|tr|td|object)>|$)',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(source)) {
      final text = _htmlToPlainText(html.group(0) ?? '');
      addCandidate(text);
    }

    // TOC/index files in CHM often contain plain visible titles near Local/Name
    // fields. Extract only such labeled snippets; do not scan arbitrary binary.
    for (final match in RegExp(
      r'(?:Name|Local|Title)\s*[:=]?\s*([^\n\r<>]{8,180})',
      caseSensitive: false,
    ).allMatches(source)) {
      addCandidate(match.group(1) ?? '');
    }
  }

  final deduped = <String>[];
  final seen = <String>{};
  for (final line in candidates) {
    final key = line.toLowerCase();
    if (seen.add(key)) deduped.add(line);
  }

  final preview = deduped.take(4000).join('\n');
  if (!_looksLikeReadableDocumentPreview(preview, minLetters: 80, minWords: 18)) {
    return 'CHM-файл сохранён и синхронизируется как оригинал. Внутренний CHM-контент обычно сжат в ITSF/LZX; без нативного CHM-адаптера безопасно извлечь главы не удалось. Чтобы не показывать “кракозябры”, ReadArc отображает это сообщение вместо бинарного мусора.';
  }

  return preview;
}

Future<String> _extractChmPreviewFromFile(File sourceFile) async {
  try {
    final length = await sourceFile.length();
    final maxBytes = length.clamp(0, 3 * 1024 * 1024).toInt();
    final raf = await sourceFile.open();
    try {
      final bytes = await raf.read(maxBytes);
      return _extractChmText(Uint8List.fromList(bytes));
    } finally {
      await raf.close();
    }
  } catch (_) {
    return _safeUnsupportedBinaryPreview('CHM');
  }
}

Future<_Fb2Document> _parseChmDocumentFromFile(File sourceFile) async {
  try {
    final extracted = await _tryExtractChmWithNativeTools(sourceFile);
    if (extracted.isNotEmpty) {
      final doc = _parseExtractedHtmlDocument(extracted, formatLabel: 'CHM');
      if (doc.blocks.length > 1 || (doc.blocks.isNotEmpty && doc.blocks.first.plainText.length > 120)) {
        return doc;
      }
    }

    final preview = await _extractChmPreviewFromFile(sourceFile);
    final blocks = preview
        .split(RegExp(r'\n{2,}'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map((part) => _Fb2Block.paragraph([_Fb2Inline(part)]))
        .toList(growable: false);
    return _makeFb2Document(
      blocks.isEmpty
          ? [
              _Fb2Block.paragraph([_Fb2Inline(_safeUnsupportedBinaryPreview('CHM'))]),
            ]
          : blocks,
    );
  } catch (error, stackTrace) {
    debugPrint('CHM adapter failure: $error\n$stackTrace');
    return _formatAdapterFailureDocument('CHM', 'CHM-адаптер завершился ошибкой: $error');
  }
}

Future<List<File>> _tryExtractChmWithNativeTools(File sourceFile) async {
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return const [];
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('readarc_chm_');
    final attempts = <Future<ProcessResult> Function()>[
      () => _runNativeTool('extract_chmLib', [sourceFile.path, tempDir!.path], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('7z', [
        'x',
        '-y',
        '-o${tempDir!.path}',
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('7zz', [
        'x',
        '-y',
        '-o${tempDir!.path}',
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('unar', [
        '-quiet',
        '-o',
        tempDir!.path,
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
    ];
    for (final attempt in attempts) {
      try {
        final result = await attempt();
        if (result.exitCode == 0) {
          final files = await _collectReadableDocumentFiles(tempDir);
          if (files.isNotEmpty) return files;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return const [];
}

Future<_Fb2Document> _parseDjvuDocumentFromFile(File sourceFile) async {
  final pageCount = await _readDjvuPageCount(sourceFile) ?? 0;
  return _makeFb2Document([
    const _Fb2Block.title('DJVU'),
    _Fb2Block.paragraph([
      _Fb2Inline(
        'DJVU-файл распознан встроенным ReadArc probe. Страниц: ${pageCount <= 0 ? 'не определено' : pageCount}. Внешние DjVuLibre/ddjvu/djvused больше не используются. Полный рендер страниц переводится на встроенный djvu-rs engine.',
      ),
    ]),
  ]);
}

Future<_Fb2Document?> _tryExtractDjvuText(File sourceFile) async {
  // No shell tools in production. Text extraction will be provided by the same
  // embedded djvu-rs engine as page rendering.
  return null;
}

Future<int?> _readDjvuPageCount(File sourceFile) async {
  try {
    final length = await sourceFile.length();
    final limit = length < 16 * 1024 * 1024 ? length : 16 * 1024 * 1024;
    final bytes = await sourceFile.openRead(0, limit).fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
      builder.add(chunk);
      return builder;
    });
    final probe = DjvuEmbeddedProbe.inspect(bytes.takeBytes());
    if (probe.isDjvu && probe.pageCount > 0) return probe.pageCount;
  } catch (error) {
    debugPrint('Embedded DJVU probe failed: $error');
  }
  return null;
}

Future<String> _resolveNativeTool(String executable) async {
  if (executable.contains(Platform.pathSeparator)) return executable;
  final candidates = <String>[
    executable,
    if (Platform.isMacOS) '/opt/homebrew/bin/$executable',
    if (Platform.isMacOS) '/usr/local/bin/$executable',
    if (Platform.isMacOS) '/opt/local/bin/$executable',
    if (!Platform.isWindows) '/usr/bin/$executable',
    if (!Platform.isWindows) '/bin/$executable',
  ];
  for (final candidate in candidates.skip(1)) {
    try {
      final file = File(candidate);
      if (await file.exists()) return candidate;
    } catch (_) {}
  }
  return executable;
}

Future<ProcessResult> _runNativeTool(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  Process? process;
  final stdout = <int>[];
  final stderr = <int>[];
  try {
    final resolvedExecutable = await _resolveNativeTool(executable);
    process = await Process.start(resolvedExecutable, arguments, runInShell: Platform.isWindows);
    final stdoutDone = process.stdout.listen(stdout.addAll).asFuture<void>();
    final stderrDone = process.stderr.listen(stderr.addAll).asFuture<void>();
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process?.kill(ProcessSignal.sigkill);
        throw TimeoutException('Native tool timeout: $executable', timeout);
      },
    );
    await Future.wait([stdoutDone, stderrDone]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return ProcessResult(
      process.pid,
      exitCode,
      utf8.decode(stdout, allowMalformed: true),
      utf8.decode(stderr, allowMalformed: true),
    );
  } on TimeoutException {
    try {
      process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    rethrow;
  }
}

Future<List<File>> _collectReadableDocumentFiles(Directory root) async {
  final files = <File>[];
  if (!await root.exists()) return files;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (lower.endsWith('.html') ||
        lower.endsWith('.htm') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.hhc') ||
        lower.endsWith('.hhk')) {
      files.add(entity);
    }
  }
  files.sort((a, b) {
    final an = a.uri.pathSegments.isEmpty ? a.path.toLowerCase() : a.uri.pathSegments.last.toLowerCase();
    final bn = b.uri.pathSegments.isEmpty ? b.path.toLowerCase() : b.uri.pathSegments.last.toLowerCase();
    int rank(String name) {
      if (name.contains('index') || name.contains('default') || name.endsWith('.hhc')) return 0;
      if (name.contains('toc') || name.contains('contents')) return 1;
      return 2;
    }

    final r = rank(an).compareTo(rank(bn));
    return r != 0 ? r : an.compareTo(bn);
  });
  return files.take(80).toList(growable: false);
}

_Fb2Document _parseExtractedHtmlDocument(List<File> files, {required String formatLabel}) {
  final blocks = <_Fb2Block>[];
  var blockBudget = 1800;
  var imageBudgetBytes = 24 * 1024 * 1024;
  for (final file in files.take(80)) {
    if (blockBudget <= 0) break;
    Uint8List fileBytes;
    try {
      if (file.lengthSync() > 8 * 1024 * 1024) continue;
      fileBytes = file.readAsBytesSync();
    } catch (_) {
      continue;
    }
    final html = _decodeTextFile(fileBytes);
    final title = _htmlTitle(html) ?? file.uri.pathSegments.last;
    final clean = html
        .replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', caseSensitive: false, dotAll: true), ' ')
        .replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true), ' ');
    if (title.trim().isNotEmpty) blocks.add(_Fb2Block.title(_decodeXmlEntities(title).trim()));
    for (final img in RegExp(
      r'''<img\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"][^>]*>''',
      caseSensitive: false,
    ).allMatches(clean)) {
      final image = _readImageNearHtml(file, img.group(1) ?? '');
      if (image != null && imageBudgetBytes > 0) {
        imageBudgetBytes -= image.length;
        blocks.add(_Fb2Block.image(image));
      }
    }
    final blockRe = RegExp(
      r'<h[1-6]\b[^>]*>.*?</h[1-6]>|<p\b[^>]*>.*?</p>|<li\b[^>]*>.*?</li>|<tr\b[^>]*>.*?</tr>|<div\b[^>]*>.*?</div>',
      caseSensitive: false,
      dotAll: true,
    );
    var found = false;
    for (final match in blockRe.allMatches(clean)) {
      final raw = match.group(0) ?? '';
      final text = _htmlToPlainText(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || text.length < 2) continue;
      found = true;
      if (blockBudget-- <= 0) break;
      if (raw.startsWith(RegExp(r'<h[1-6]', caseSensitive: false))) {
        blocks.add(_Fb2Block.title(text));
      } else if (raw.startsWith(RegExp(r'<li', caseSensitive: false))) {
        blocks.add(_Fb2Block.paragraph([_Fb2Inline('• $text')]));
      } else {
        blocks.add(_Fb2Block.paragraph(_parseHtmlInlines(raw, file.path)));
      }
    }
    if (!found) {
      final text = _htmlToPlainText(clean).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) blocks.add(_Fb2Block.paragraph([_Fb2Inline(text)]));
    }
  }
  if (blocks.isEmpty) {
    return _makeFb2Document([
      _Fb2Block.paragraph([_Fb2Inline('Не удалось извлечь HTML-главы из $formatLabel.')]),
    ]);
  }
  return _makeFb2Document(blocks);
}

String? _htmlTitle(String html) {
  final title = RegExp(r'<title\b[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(1);
  if (title != null && title.trim().isNotEmpty) return _htmlToPlainText(title).trim();
  final heading = RegExp(r'<h1\b[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(1);
  if (heading != null && heading.trim().isNotEmpty) return _htmlToPlainText(heading).trim();
  return null;
}

Uint8List? _readImageNearHtml(File htmlFile, String srcRaw) {
  var src = _decodeXmlEntities(srcRaw).trim();
  if (src.isEmpty || src.startsWith('http://') || src.startsWith('https://') || src.startsWith('data:')) return null;
  final hash = src.indexOf('#');
  if (hash >= 0) src = src.substring(0, hash);
  final query = src.indexOf('?');
  if (query >= 0) src = src.substring(0, query);
  try {
    src = Uri.decodeFull(src);
  } catch (_) {}
  final base = htmlFile.parent.uri;
  final resolved = base.resolve(src).toFilePath();
  final file = File(resolved);
  try {
    if (file.existsSync() && file.lengthSync() <= 6 * 1024 * 1024) return file.readAsBytesSync();
  } catch (_) {}
  return null;
}

bool _looksLikeReadableDocumentPreview(String text, {required int minLetters, required int minWords}) {
  final normalized = text.trim();
  if (normalized.length < 80) return false;
  final letters = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(normalized).length;
  final words = RegExp(r'[A-Za-zА-Яа-яЁё]{2,}').allMatches(normalized).length;
  final replacement = '�'.allMatches(normalized).length;
  final controls = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').allMatches(normalized).length;
  final suspicious = RegExp(r'[þÿÐðªº§¤¦¶]').allMatches(normalized).length;
  final len = normalized.length;
  if (letters < minLetters || words < minWords) return false;
  if (replacement > 0 || controls > 0) return false;
  if (suspicious / len > 0.015) return false;
  if (letters / len < 0.45) return false;
  return true;
}

String _extractSingleByteRuns(Uint8List bytes, {required int minLength}) {
  final lines = <String>[];
  final current = <int>[];
  void flush() {
    if (current.length >= minLength) {
      final decoded = _decodeWindows1251(current);
      lines.add(decoded);
    }
    current.clear();
  }

  for (final byte in bytes) {
    final printable = byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte <= 0x7E) || byte >= 0x80;
    if (printable) {
      current.add(byte);
    } else {
      flush();
    }
  }
  flush();
  return lines.join('\n');
}

String _extractUtf16LeRuns(Uint8List bytes, {required int minLength}) {
  final lines = <String>[];
  final codes = <int>[];

  bool allowed(int code) =>
      code == 0x09 ||
      code == 0x0A ||
      code == 0x0D ||
      (code >= 0x20 && code <= 0x7E) ||
      (code >= 0x0400 && code <= 0x052F) ||
      code == 0x00A0 ||
      code == 0x00AB ||
      code == 0x00BB ||
      code == 0x2013 ||
      code == 0x2014 ||
      code == 0x2026 ||
      code == 0x2116;

  void flush() {
    if (codes.length >= minLength) lines.add(String.fromCharCodes(codes));
    codes.clear();
  }

  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final code = bytes[i] | (bytes[i + 1] << 8);
    if (allowed(code)) {
      codes.add(code);
    } else {
      flush();
    }
  }
  flush();
  return lines.join('\n');
}

bool _looksReadableChmLine(String line) {
  final text = line.trim();
  if (text.length < 8 || text.length > 360) return false;
  if (RegExp(r'^[\W_\d]+$').hasMatch(text)) return false;
  if (RegExp(r'(?:[A-Za-z]:\\|/)[^ ]{20,}').hasMatch(text)) return false;
  final letters = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(text).length;
  final bad = RegExp(r'[�\x00-\x08\x0B\x0C\x0E-\x1F]').allMatches(text).length;
  final symbols = RegExp(r'''[^A-Za-zА-Яа-яЁё0-9 .,;:!?()\[\]{}<>«»"'\-–—/\n\t]''').allMatches(text).length;
  final len = text.length;
  if (letters / len < 0.35) return false;
  if (bad / len > 0.02) return false;
  if (symbols / len > 0.14) return false;
  return true;
}

Uint8List _archiveFileBytes(ArchiveFile file) {
  final content = file.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  throw StateError('Не удалось прочитать файл EPUB: ${file.name}');
}

String? _xmlAttr(String tag, String name) {
  final match = RegExp("$name\\s*=\\s*[\"']([^\"']+)[\"']", caseSensitive: false).firstMatch(tag);
  return match?.group(1);
}

String _zipDirName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '' : normalized.substring(0, index);
}

String _joinZipPath(String baseDir, String href) {
  final parts = <String>[];
  final cleanedHref = href.trim().replaceAll('\\', '/');
  final joined = cleanedHref.startsWith('/') || baseDir.isEmpty
      ? cleanedHref.replaceFirst(RegExp(r'^/+'), '')
      : '$baseDir/$cleanedHref';
  final raw = joined.split('/');
  for (final part in raw) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      try {
        parts.add(Uri.decodeFull(part));
      } catch (_) {
        parts.add(part);
      }
    }
  }
  return parts.join('/');
}

String _htmlToPlainText(String html) {
  var text = html;
  text = text.replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'</(p|div|section|article|chapter|h[1-6]|li|tr)>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
  return _decodeXmlEntities(text).replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').replaceAll(RegExp(r'\n\s+'), '\n');
}

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
  text = text.split('\n').map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trimRight()).join('\n');
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
    0x0402,
    0x0403,
    0x201A,
    0x0453,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x20AC,
    0x2030,
    0x0409,
    0x2039,
    0x040A,
    0x040C,
    0x040B,
    0x040F,
    0x0452,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x0000,
    0x2122,
    0x0459,
    0x203A,
    0x045A,
    0x045C,
    0x045B,
    0x045F,
    0x00A0,
    0x040E,
    0x045E,
    0x0408,
    0x00A4,
    0x0490,
    0x00A6,
    0x00A7,
    0x0401,
    0x00A9,
    0x0404,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x0407,
    0x00B0,
    0x00B1,
    0x0406,
    0x0456,
    0x0491,
    0x00B5,
    0x00B6,
    0x00B7,
    0x0451,
    0x2116,
    0x0454,
    0x00BB,
    0x0458,
    0x0405,
    0x0455,
    0x0457,
    0x0410,
    0x0411,
    0x0412,
    0x0413,
    0x0414,
    0x0415,
    0x0416,
    0x0417,
    0x0418,
    0x0419,
    0x041A,
    0x041B,
    0x041C,
    0x041D,
    0x041E,
    0x041F,
    0x0420,
    0x0421,
    0x0422,
    0x0423,
    0x0424,
    0x0425,
    0x0426,
    0x0427,
    0x0428,
    0x0429,
    0x042A,
    0x042B,
    0x042C,
    0x042D,
    0x042E,
    0x042F,
    0x0430,
    0x0431,
    0x0432,
    0x0433,
    0x0434,
    0x0435,
    0x0436,
    0x0437,
    0x0438,
    0x0439,
    0x043A,
    0x043B,
    0x043C,
    0x043D,
    0x043E,
    0x043F,
    0x0440,
    0x0441,
    0x0442,
    0x0443,
    0x0444,
    0x0445,
    0x0446,
    0x0447,
    0x0448,
    0x0449,
    0x044A,
    0x044B,
    0x044C,
    0x044D,
    0x044E,
    0x044F,
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
              'Формат ${book.format.toUpperCase()} добавлен в библиотеку, но полноценный renderer ещё не подключён.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Production-версия должна подключить встроенные Readium/PDFium/DJVU/CHM/DOCX engines и сохранять locator для каждого формата.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLocalDateTimeSeconds(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.storage, required this.sync});

  final StorageService storage;
  final SyncService sync;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _accountController = TextEditingController();
  final _deviceNameController = TextEditingController();
  final _pairingInputController = TextEditingController();
  LibraryManifest? _manifest;
  SyncSettings? _settings;
  bool _busy = false;
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
    _accountController.dispose();
    _deviceNameController.dispose();
    _pairingInputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    final settings = (await widget.storage.loadSyncSettings()).asOfficial(autoConnect: true);
    await widget.storage.saveSyncSettings(settings);
    if (!mounted) return;
    _manifest = manifest;
    _settings = settings;
    _accountController.text = manifest.accountId;
    _deviceNameController.text = manifest.deviceName;
    setState(() {});
  }

  SyncSettings _settingsFromForm({bool? autoConnect}) =>
      SyncSettings(autoConnect: autoConnect ?? true).asOfficial(autoConnect: true);

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceNameController.text.trim());
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Название устройства'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Название устройства',
            helperText: 'Это имя будет видно другим доверенным устройствам.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Сохранить')),
        ],
      ),
    );
    controller.dispose();
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty || normalized == _deviceNameController.text.trim()) return;
    setState(() => _busy = true);
    try {
      final manifest = await widget.storage.changeDeviceName(normalized);
      await widget.sync.broadcastLibrarySnapshot(reason: 'device_name_changed');
      if (!mounted) return;
      _deviceNameController.text = manifest.deviceName;
      setState(() => _manifest = manifest);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Название устройства сохранено')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не удалось изменить название устройства: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAccountId() async {
    final controller = TextEditingController(text: _accountController.text.trim());
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Аккаунт'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Аккаунт',
            helperText: 'Обычно менять не нужно. Используйте только для восстановления/переноса аккаунта вручную.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Сохранить')),
        ],
      ),
    );
    controller.dispose();
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty || normalized == _accountController.text.trim()) return;
    setState(() => _busy = true);
    try {
      await widget.sync.disconnect();
      final manifest = await widget.storage.changeAccountId(normalized);
      if (!mounted) return;
      _accountController.text = manifest.accountId;
      setState(() => _manifest = manifest);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аккаунт сохранён')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось изменить аккаунт: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createPairingInvite() async {
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      await widget.storage.saveSyncSettings(settings);
      final invite = await widget.sync.createPairingInvite(settings: settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _pairingInvite = invite;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код подключения создан')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать код: $error')));
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<PairingInvite?> _ensurePairingInvite({bool forceFresh = false}) async {
    final existing = _pairingInvite;
    if (!forceFresh && existing != null && !existing.isNearExpiry) return existing;
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать QR-код: $error')));
      return null;
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _showPairingQrCode() async {
    final invite = await _ensurePairingInvite(forceFresh: true);
    if (!mounted || invite == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR-код подключения'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: invite.code, version: QrVersions.auto, size: 260, backgroundColor: Colors.white),
            const SizedBox(height: 12),
            Text('Код: ${invite.displayCode}'),
            const SizedBox(height: 4),
            Text(
              'Действует до: ${_formatLocalDateTimeSeconds(invite.expiresAt)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Отсканируйте QR на подключаемом устройстве.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть'))],
      ),
    );
  }

  String _pairingCodeFromScannedValue(String scanned) {
    final raw = scanned.trim();
    if (raw.startsWith('readarc://')) {
      final uri = Uri.tryParse(raw);
      final code = uri == null ? '' : (uri.queryParameters['code'] ?? '');
      final digits = code.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length == 6) return digits;
    }
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 6 ? digits.substring(0, 6) : digits;
  }

  Future<void> _scanPairingQrCode() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Сканирование QR-кода доступно на мобильных устройствах.')));
      return;
    }
    final scanned = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _PairingQrScannerScreen()));
    if (scanned == null || scanned.trim().isEmpty || !mounted) return;
    _pairingInputController.text = _pairingCodeFromScannedValue(scanned);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Подключено к аккаунту ${result.ownerDeviceName}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось подключиться по коду: $error')));
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _copyAccountId() async {
    await Clipboard.setData(ClipboardData(text: _accountController.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аккаунт скопирован')));
  }

  Future<void> _revokeTrustedDevice(TrustedDeviceRecord device) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отозвать доступ?'),
        content: Text(
          'Устройство «${device.name}» потеряет право участвовать в синхронизации этого аккаунта. Его события и передачи файлов будут отклоняться другими устройствами.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Отозвать доступ')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await widget.storage.revokeTrustedDevice(device.deviceId);
      await widget.sync.broadcastLibrarySnapshot(reason: 'trusted_device_revoked');
      if (!mounted) return;
      setState(() => _manifest = updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось отозвать доступ: $error')));
    }
  }

  Future<void> _pruneTrustedDevices() async {
    try {
      final updated = await widget.storage.pruneDeletedTrustedDevices();
      if (!mounted) return;
      setState(() => _manifest = updated);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список устройств очищен')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось очистить список: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    if (manifest == null || _settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final revokedTrustedDevices = manifest.trustedDevices.where((device) => device.isRevoked).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ValueListenableBuilder<SyncStateSnapshot>(
        valueListenable: widget.sync.state,
        builder: (context, syncState, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _SectionCard(
                title: 'Устройство',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            manifest.deviceName,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _editDeviceName,
                          icon: const Icon(Icons.edit_rounded),
                          label: const Text('Редактировать'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Статус подключения: ${syncState.statusText}'),
                    if (manifest.isCurrentDeviceRevoked) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Доступ этого устройства отозван. Локальная библиотека остаётся доступной, но синхронизация остановлена. Для повторного подключения отсканируйте новый QR-код владельца аккаунта.',
                      ),
                    ],
                  ],
                ),
              ),
              _SectionCard(
                title: 'Подключение',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      FilledButton.icon(
                        onPressed: _pairingBusy ? null : _scanPairingQrCode,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Сканировать QR'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _pairingInputController,
                      decoration: const InputDecoration(labelText: 'Введите код приглашения'),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) {
                        if (!_pairingBusy) unawaited(_claimPairingInvite());
                      },
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _pairingBusy ? null : _claimPairingInvite,
                        icon: _pairingBusy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login_rounded),
                        label: const Text('Подключиться по коду'),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Другое устройство',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _pairingBusy ? null : _showPairingQrCode,
                            icon: _pairingBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.qr_code_2_rounded),
                            label: const Text('Показать QR'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pairingBusy ? null : _createPairingInvite,
                            icon: const Icon(Icons.pin_rounded),
                            label: const Text('Создать код подключения'),
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
                            Center(
                              child: Text(
                                _pairingInvite!.displayCode,
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 6),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Center(
                              child: Text('Действует до: ${_formatLocalDateTimeSeconds(_pairingInvite!.expiresAt)}'),
                            ),
                            const SizedBox(height: 10),
                            const Center(child: Text('Введите код на подключаемом устройстве.')),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Card(
                child: ExpansionTile(
                  title: const Text('Доверенные устройства'),
                  subtitle: Text(
                    manifest.activeTrustedDevices.isEmpty
                        ? 'Пока только текущее устройство'
                        : 'Доверенных: ${manifest.activeTrustedDevices.length}${revokedTrustedDevices > 0 ? ', отозвано: $revokedTrustedDevices' : ''}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText('Аккаунт: ${manifest.accountId}'),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _editAccountId,
                                icon: const Icon(Icons.manage_accounts_rounded),
                                label: const Text('Редактировать аккаунт'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _copyAccountId,
                                icon: const Icon(Icons.copy_rounded),
                                label: const Text('Скопировать аккаунт'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SelectableText('Идентификатор устройства: ${manifest.deviceId}'),
                          SelectableText(
                            "Ключ устройства: ${manifest.currentDeviceTrust?.effectiveFingerprint ?? 'не создан'}",
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 28),
                    if (manifest.activeTrustedDevices.isEmpty)
                      const Align(alignment: Alignment.centerLeft, child: Text('Пока только текущее устройство'))
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Доступ можно отозвать у любого другого устройства. Повторное подключение возможно по новому QR-коду владельца аккаунта.',
                          ),
                          const SizedBox(height: 8),
                          ...manifest.activeTrustedDevices.map((device) {
                            final isCurrent = device.deviceId == manifest.deviceId;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(isCurrent ? Icons.phone_iphone_rounded : Icons.devices_rounded),
                              title: Text('${device.name}${isCurrent ? ' • это устройство' : ''}'),
                              subtitle: Text(
                                '${device.role} • ${device.trustStatusLabel}\n'
                                'Ключ: ${device.effectiveFingerprint}\n'
                                'Права: metadata ${device.canSyncMetadata ? '✓' : '—'}, files ${device.canTransferFiles ? '✓' : '—'}',
                              ),
                              trailing: isCurrent
                                  ? null
                                  : IconButton(
                                      tooltip: 'Отозвать доступ устройства',
                                      icon: const Icon(Icons.block_rounded),
                                      onPressed: () => _revokeTrustedDevice(device),
                                    ),
                            );
                          }),
                          if (manifest.trustedDevices.any((device) => device.isRevoked)) ...[
                            const Divider(height: 24),
                            const Text('Отозванные устройства'),
                            const SizedBox(height: 8),
                            ...manifest.trustedDevices
                                .where((device) => device.isRevoked)
                                .map(
                                  (device) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.block_rounded),
                                    title: Text(device.name),
                                    subtitle: Text(
                                      '${device.deviceId}\nКлюч: ${device.effectiveFingerprint}\nОтозвано: ${device.deletedAt?.toLocal() ?? ''}',
                                    ),
                                  ),
                                ),
                          ],
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _pruneTrustedDevices,
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Очистить старые отозванные записи'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Card(
                child: ExpansionTile(
                  initiallyExpanded: _logExpanded,
                  onExpansionChanged: (value) => setState(() => _logExpanded = value),
                  title: const Text('Журнал событий'),
                  subtitle: Text(
                    syncState.logLines.isEmpty ? 'Пока нет событий' : 'Событий: ${syncState.logLines.length}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    if (syncState.logLines.isEmpty)
                      const Align(alignment: Alignment.centerLeft, child: Text('Пока нет событий'))
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
  final _qrKey = GlobalKey(debugLabel: 'ReadArcQrScanner');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _subscription;
  bool _handled = false;

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    _subscription = controller.scannedDataStream.listen(
      (scan) {
        if (_handled) return;
        final value = scan.code;
        if (value == null || value.trim().isEmpty) return;
        _handled = true;
        unawaited(_subscription?.cancel());
        _subscription = null;
        unawaited(controller.pauseCamera());
        if (mounted) Navigator.of(context).pop(value.trim());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('ReadArc QR scanner stream error: $error\n$stackTrace');
      },
    );
  }

  @override
  void reassemble() {
    super.reassemble();
    final controller = _controller;
    if (controller == null) return;
    if (Platform.isAndroid) {
      unawaited(controller.pauseCamera());
    }
    unawaited(controller.resumeCamera());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать QR')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                QRView(
                  key: _qrKey,
                  onQRViewCreated: _onQRViewCreated,
                  overlay: QrScannerOverlayShape(
                    borderColor: _raWarmGold,
                    borderRadius: 14,
                    borderLength: 28,
                    borderWidth: 7,
                    cutOutSize: MediaQuery.sizeOf(context).shortestSide * 0.68,
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      child: Text(
                        'Наведите камеру на QR-код ReadArc. После сканирования будет использован только 6-значный код подключения.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('Ввести код вручную'),
              ),
            ),
          ),
        ],
      ),
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
