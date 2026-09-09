import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/app/readarc_app.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  testWidgets(
    'system Back commits the current PDF page before the debounce fires',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'readarc-reader-exit-',
      );
      final storage = StorageService(
        appDirectory: () async => directory,
        secretStore: _MemorySecretStore(),
      );
      final sync = SyncService(storage);
      final fixture = File('test/fixtures/pdf_characterization.pdf').absolute;
      final book = BookRecord(
        id: 'pdf-exit-regression',
        title: 'PDF exit regression',
        fileName: fixture.uri.pathSegments.last,
        format: 'pdf',
        sizeBytes: await fixture.length(),
        contentSha256: 'fixture',
        localPath: fixture.path,
      );
      await storage.upsertBook(book);

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await sync.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => ReaderScreen(
                        book: book,
                        storage: storage,
                        sync: sync,
                      ),
                    ),
                  ),
                  child: const Text('Open PDF'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open PDF'));

      for (
        var attempt = 0;
        attempt < 100 && find.text('1 / 2').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('1 / 2'), findsOneWidget);

      final progress = find.byType(LinearProgressIndicator);
      expect(progress, findsOneWidget);
      await tester.tap(progress);
      await tester.pump();
      final progressRect = tester.getRect(progress);
      await tester.tapAt(
        Offset(progressRect.right - 2, progressRect.center.dy),
      );
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Open PDF'), findsOneWidget);

      final saved = (await storage.loadManifest()).books.singleWhere(
        (candidate) => candidate.id == book.id,
      );
      final locator = jsonDecode(saved.currentLocator) as Map<String, dynamic>;
      expect(locator['type'], 'pdf-page-v1');
      expect(locator['page'], 2);
    },
  );
}

class _MemorySecretStore implements LibrarySecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
