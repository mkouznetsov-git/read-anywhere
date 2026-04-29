import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'models/book.dart';
import 'models/manifest.dart';
import 'services/book_import_service.dart';
import 'services/storage_service.dart';
import 'ui/app_theme.dart';

void main() {
  runApp(const ReadAnywhereApp());
}

class ReadAnywhereApp extends StatelessWidget {
  const ReadAnywhereApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Read anywhere',
      theme: ReadAnywhereTheme.light(),
      home: const LibraryScreen(),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _storage = StorageService();
  late final _importService = BookImportService(_storage);
  LibraryManifest? _manifest;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final manifest = await _storage.loadManifest();
    if (mounted) setState(() => _manifest = manifest);
  }

  Future<void> _addBook() async {
    setState(() => _busy = true);
    try {
      await _importService.pickAndImport();
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

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.books ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Read anywhere'),
        actions: [
          IconButton(
            tooltip: 'Синхронизация',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SyncPlaceholderScreen()),
            ),
            icon: const Icon(Icons.sync_rounded),
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
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return _BookCard(
                      book: book,
                      onOpen: book.isDownloaded
                          ? () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ReaderScreen(book: book),
                                ),
                              );
                              await _reload();
                            }
                          : null,
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
  const _BookCard({required this.book, required this.onOpen});

  final BookRecord book;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final statusText = book.isDownloaded ? 'Скачана' : 'Только в библиотеке';
    final progress = book.progressPercent.clamp(0, 100).toStringAsFixed(1);

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
              Text('Прогресс: $progress%'),
            ],
          ),
        ),
        trailing: IconButton(
          tooltip: book.isDownloaded ? 'Читать' : 'Скачать позже',
          onPressed: onOpen,
          icon: Icon(book.isDownloaded
              ? Icons.menu_book_rounded
              : Icons.cloud_download_outlined),
        ),
      ),
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});

  final BookRecord book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _storage = StorageService();
  final _controller = ScrollController();
  String? _text;
  Timer? _saveDebounce;
  double _lastProgress = 0;

  @override
  void initState() {
    super.initState();
    _lastProgress = widget.book.progressPercent;
    _load();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.book.localPath == null) return;
    if (widget.book.format != 'txt') {
      setState(() => _text = null);
      return;
    }
    final file = File(widget.book.localPath!);
    final raw = await file.readAsString();
    if (!mounted) return;
    setState(() => _text = raw);

    // Restore approximate position after first layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      _controller.jumpTo(max * (widget.book.progressPercent / 100));
    });
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) return;
    final progress = ((_controller.offset / max) * 100).clamp(0, 100).toDouble();
    _lastProgress = progress;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      _storage.updateProgress(
        bookId: widget.book.id,
        progressPercent: progress,
        locator: 'txt-scroll:${_controller.offset.toStringAsFixed(0)}',
      );
    });
  }

  Future<void> _addBookmark() async {
    await _storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: 'txt-scroll:${_controller.hasClients ? _controller.offset.toStringAsFixed(0) : 0}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Закладка добавлена')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTxt = widget.book.format == 'txt';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Добавить закладку',
            onPressed: _addBookmark,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
        ],
      ),
      body: !isTxt
          ? _UnsupportedReaderPlaceholder(book: widget.book)
          : _text == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _controller,
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
                        child: SelectableText(
                          _text!,
                          style: const TextStyle(fontSize: 18, height: 1.65),
                        ),
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
                            Text('${_lastProgress.toStringAsFixed(1)}%'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
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

class SyncPlaceholderScreen extends StatelessWidget {
  const SyncPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MVP-заготовка', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            SizedBox(height: 12),
            Text('Здесь должны быть: pairing QR-код, список устройств, выбор книг для скачивания и журнал синхронизации.'),
            SizedBox(height: 12),
            Text('Transport-wrapper см. в services/sync/relay_client.dart, merge rules — в services/sync/merge.dart.'),
          ],
        ),
      ),
    );
  }
}
