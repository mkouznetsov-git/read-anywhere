import 'dart:async';
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
  void dispose() {
    unawaited(_sync.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Read anywhere',
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

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.books ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Read anywhere'),
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
    required this.transfer,
  });

  final BookRecord book;
  final String currentDeviceId;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
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
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
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
      unawaited(_saveProgress(progress));
    });
  }

  Future<void> _saveProgress(double progress) async {
    await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: progress,
      locator: 'txt-scroll:${_controller.offset.toStringAsFixed(0)}',
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'progress_updated');
  }

  Future<void> _addBookmark() async {
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator:
          'txt-scroll:${_controller.hasClients ? _controller.offset.toStringAsFixed(0) : 0}',
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
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
  final _accountController = TextEditingController();
  final _deviceNameController = TextEditingController();
  LibraryManifest? _manifest;
  SyncSettings? _settings;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _relayController.dispose();
    _accountController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    final settings = await widget.storage.loadSyncSettings();
    if (!mounted) return;
    _manifest = manifest;
    _settings = settings;
    _relayController.text = settings.relayUrl;
    _accountController.text = manifest.accountId;
    _deviceNameController.text = manifest.deviceName;
    setState(() {});
  }

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
      await widget.storage.saveSyncSettings(
        SyncSettings(relayUrl: _relayController.text.trim()),
      );
      await widget.sync.connect(relayUrl: _relayController.text.trim());
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
  }

  Future<void> _sendSnapshot() async {
    final sent = await widget.sync.broadcastLibrarySnapshot(reason: 'manual');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? 'Snapshot отправлен' : 'Сначала подключитесь к relay')),
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
                    Text('Отправлено событий: ${syncState.sentEvents}'),
                    Text('Получено событий: ${syncState.receivedEvents}'),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Relay через интернет',
                child: Column(
                  children: [
                    TextField(
                      controller: _relayController,
                      decoration: const InputDecoration(
                        labelText: 'Relay URL',
                        helperText: 'Например: http://your-server:8787',
                      ),
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
                  ],
                ),
              ),
              _SectionCard(
                title: 'Pairing MVP',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Для теста Mac ↔ Android укажите одинаковый accountId на обоих устройствах. Это временный ручной pairing; QR-код и ключи будут в следующем спринте.',
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
