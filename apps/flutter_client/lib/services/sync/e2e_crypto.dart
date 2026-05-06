import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class ReadAnywhereE2eCrypto {
  static const version = 'readanywhere-e2e-v1';
  static final _algorithm = AesGcm.with256bits();
  static final _random = Random.secure();

  static Future<Map<String, dynamic>> encryptPayload({
    required Map<String, dynamic> payload,
    required String accountEncryptionKey,
    required String eventType,
  }) async {
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final clearText = utf8.encode(jsonEncode(payload));
    final secretBox = await _algorithm.encrypt(
      clearText,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: utf8.encode(eventType),
    );
    return {
      'e2ee': {
        'v': version,
        'alg': 'AES-256-GCM',
        'aad': eventType,
        'nonce': _base64UrlNoPadding(secretBox.nonce),
        'ciphertext': _base64UrlNoPadding(secretBox.cipherText),
        'mac': _base64UrlNoPadding(secretBox.mac.bytes),
      },
    };
  }

  static Future<Map<String, dynamic>> decryptPayload({
    required Map<String, dynamic> encryptedPayload,
    required String accountEncryptionKey,
    required String eventType,
  }) async {
    final e2eeRaw = encryptedPayload['e2ee'];
    if (e2eeRaw is! Map) return encryptedPayload;
    final e2ee = Map<String, dynamic>.from(e2eeRaw);
    if (e2ee['v'] != version) {
      throw StateError('Неподдерживаемая версия E2E payload: ${e2ee['v']}');
    }
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final nonce = _decodeBase64UrlNoPadding(e2ee['nonce']?.toString() ?? '');
    final cipherText = _decodeBase64UrlNoPadding(e2ee['ciphertext']?.toString() ?? '');
    final mac = _decodeBase64UrlNoPadding(e2ee['mac']?.toString() ?? '');
    final clearText = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(keyBytes),
      aad: utf8.encode(eventType),
    );
    final decoded = jsonDecode(utf8.decode(clearText));
    if (decoded is! Map) throw StateError('E2E payload is not a JSON object');
    return Map<String, dynamic>.from(decoded);
  }

  static bool isEncryptedPayload(Map<String, dynamic> payload) => payload['e2ee'] is Map;

  static String _base64UrlNoPadding(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

  static List<int> _decodeBase64UrlNoPadding(String raw) {
    final normalized = raw.trim();
    final padded = normalized + ('=' * ((4 - normalized.length % 4) % 4));
    return base64Url.decode(padded);
  }
}
