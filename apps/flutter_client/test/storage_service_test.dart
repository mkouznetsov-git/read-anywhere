import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';

void main() {
  test('default repository resolves its application directory without recursion', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-storage-service-');
    addTearDown(() async => directory.delete(recursive: true));
    final storage = StorageService(appDirectory: () async => directory, secretStore: _MemorySecretStore());

    final first = await storage.loadManifest().timeout(const Duration(seconds: 3));
    final second = await storage.loadManifest().timeout(const Duration(seconds: 3));

    expect(first.accountId, isNotEmpty);
    expect(second.accountId, first.accountId);
    expect(await File('${directory.path}/manifest.json').exists(), isTrue);
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
