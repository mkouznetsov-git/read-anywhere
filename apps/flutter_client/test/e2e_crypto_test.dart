import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/sync/e2e_crypto.dart';

String _key() {
  final random = Random(42);
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
}

void main() {
  test('encrypts, signs and decrypts payload', () async {
    final encrypted = await ReadAnywhereE2eCrypto.encryptPayload(
      payload: {'hello': 'world'},
      accountEncryptionKey: _key(),
      eventType: 'library_snapshot',
      accountId: 'acc',
      deviceId: 'dev-a',
      createdAt: DateTime.utc(2030),
    );

    expect(ReadAnywhereE2eCrypto.encryptedEventId(encrypted), isNotEmpty);
    final decrypted = await ReadAnywhereE2eCrypto.decryptPayload(
      encryptedPayload: encrypted,
      accountEncryptionKey: _key(),
      eventType: 'library_snapshot',
      accountId: 'acc',
      deviceId: 'dev-a',
    );

    expect(decrypted['hello'], 'world');
  });

  test('rejects tampered signed payload', () async {
    final encrypted = await ReadAnywhereE2eCrypto.encryptPayload(
      payload: {'hello': 'world'},
      accountEncryptionKey: _key(),
      eventType: 'library_snapshot',
      accountId: 'acc',
      deviceId: 'dev-a',
    );
    final e2ee = Map<String, dynamic>.from(encrypted['e2ee'] as Map);
    e2ee['ciphertext'] = '${e2ee['ciphertext']}x';
    final tampered = {'e2ee': e2ee};

    await expectLater(
      ReadAnywhereE2eCrypto.decryptPayload(
        encryptedPayload: tampered,
        accountEncryptionKey: _key(),
        eventType: 'library_snapshot',
        accountId: 'acc',
        deviceId: 'dev-a',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
