import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:readarc/main.dart' as app;
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ReadArc migrates a pre-Sprint-46 manifest and opens the library', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    final directory = await Directory.systemTemp.createTemp('readarc-platform-upgrade-smoke-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final legacy = LibraryManifest(
      accountId: 'legacy-account',
      accountEncryptionKey: 'legacy-account-secret',
      deviceId: 'legacy-device',
      deviceName: 'Legacy device',
      deviceSigningPublicKey: 'legacy-public',
      deviceSigningPrivateKey: 'legacy-device-secret',
      trustedDevices: [TrustedDeviceRecord(deviceId: 'legacy-device', name: 'Legacy device', role: 'owner')],
    ).toJson()
      ..remove('schemaVersion')
      ..['accountEncryptionKey'] = 'legacy-account-secret'
      ..['deviceSigningPrivateKey'] = 'legacy-device-secret';
    final manifestFile = File('${directory.path}/manifest.json');
    await manifestFile.writeAsString(jsonEncode(legacy), flush: true);

    final storage = _SmokeStorage(directory);
    final sync = SyncService(storage);
    await tester.pumpWidget(app.ReadArcApp(autoConnect: false, storage: storage, sync: sync, disposeSync: false));
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(app.LibraryScreen), findsOneWidget);
      expect(find.textContaining('Библиотека пока пуста'), findsOneWidget);
      expect(find.textContaining('Не удалось загрузить библиотеку'), findsNothing);
      expect(errors, isEmpty, reason: 'ReadArc emitted a Flutter framework error during upgrade startup: $errors');

      final migratedRaw = await manifestFile.readAsString();
      final migratedJson = jsonDecode(migratedRaw) as Map<String, dynamic>;
      expect(migratedJson['schemaVersion'], LibraryManifest.currentSchemaVersion);
      expect(migratedRaw, isNot(contains('legacy-account-secret')));
      expect(migratedRaw, isNot(contains('legacy-device-secret')));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await sync.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('ReadArc creates its initial manifest and opens the empty library', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    final directory = await Directory.systemTemp.createTemp('readarc-platform-smoke-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final storage = _SmokeStorage(directory);
    final sync = SyncService(storage);
    // Relay behavior has its own real two-client integration harness. Keep the
    // platform boot smoke deterministic and independent from production DNS,
    // internet reachability and live peer traffic.
    await tester.pumpWidget(app.ReadArcApp(autoConnect: false, storage: storage, sync: sync, disposeSync: false));
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(app.LibraryScreen), findsOneWidget);
      expect(find.textContaining('Библиотека пока пуста'), findsOneWidget);
      expect(find.textContaining('Не удалось загрузить библиотеку'), findsNothing);
      expect(errors, isEmpty, reason: 'ReadArc emitted a Flutter framework error during startup: $errors');
    } finally {
      // Explicitly dispose application-owned sync streams, timers and HTTP
      // resources. Device integration runners keep the process alive while any
      // of these resources remain attached to the widget under test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await sync.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _SmokeStorage extends StorageService {
  _SmokeStorage(this.directory);

  final Directory directory;

  @override
  Future<Directory> appDir() async => directory;
}
