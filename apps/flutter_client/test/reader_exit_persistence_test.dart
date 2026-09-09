import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/reader/reader_exit_checkpoint.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';

void main() {
  testWidgets('system Back persists the current PDF locator before returning to the library', (tester) async {
    final directory = await Directory.systemTemp.createTemp('readarc-reader-exit-');
    final storage = StorageService(appDirectory: () async => directory, secretStore: _MemorySecretStore());
    final checkpointCompleted = Completer<void>();
    final book = BookRecord(
      id: 'pdf-exit-regression',
      title: 'PDF exit regression',
      fileName: 'regression.pdf',
      format: 'pdf',
      sizeBytes: 1,
      contentSha256: 'fixture',
      progressPercent: 0,
      currentLocator: jsonEncode({'type': 'pdf-page-v1', 'page': 1, 'pages': 2}),
    );
    await storage.upsertBook(book);

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ReaderExitCheckpoint(
                    onCommit: () async {
                      await storage.updateProgress(
                        bookId: book.id,
                        progressPercent: 100,
                        locator: jsonEncode({'type': 'pdf-page-v1', 'page': 2, 'pages': 2}),
                      );
                      checkpointCompleted.complete();
                    },
                    child: const Scaffold(body: Text('PDF page 2')),
                  ),
                ),
              ),
              child: const Text('Open PDF'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open PDF'));
    await tester.pumpAndSettle();
    expect(find.text('PDF page 2'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await checkpointCompleted.future.timeout(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Open PDF'), findsOneWidget);

    final saved = (await storage.loadManifest()).books.singleWhere((candidate) => candidate.id == book.id);
    final locator = jsonDecode(saved.currentLocator) as Map<String, dynamic>;
    expect(locator['type'], 'pdf-page-v1');
    expect(locator['page'], 2);
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
