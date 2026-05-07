import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';


class BinaryEncryptionResult {
  const BinaryEncryptionResult({required this.header, required this.cipherBytes});

  final Map<String, dynamic> header;
  final Uint8List cipherBytes;
}

class ReadAnywhereE2eCrypto {
  static const version = 'readanywhere-e2e-v2';
  static const legacyVersion = 'readanywhere-e2e-v1';
  static final _algorithm = AesGcm.with256bits();
  static final _random = Random.secure();

  static Future<Map<String, dynamic>> encryptPayload({
    required Map<String, dynamic> payload,
    required String accountEncryptionKey,
    required String eventType,
    String accountId = '',
    String deviceId = '',
    DateTime? createdAt,
  }) async {
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final nonce = _randomBytes(12);
    final eventId = _base64UrlNoPadding(_randomBytes(16));
    final issuedAt = (createdAt ?? DateTime.now().toUtc()).toUtc().toIso8601String();
    final clearText = utf8.encode(jsonEncode(payload));
    final aadText = _aadText(eventType, accountId, deviceId, eventId, issuedAt);
    final secretBox = await _algorithm.encrypt(
      clearText,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: utf8.encode(aadText),
    );
    final nonceText = _base64UrlNoPadding(secretBox.nonce);
    final cipherText = _base64UrlNoPadding(secretBox.cipherText);
    final macText = _base64UrlNoPadding(secretBox.mac.bytes);
    final signature = _signEnvelope(
      keyBytes: keyBytes,
      accountId: accountId,
      deviceId: deviceId,
      eventType: eventType,
      eventId: eventId,
      issuedAt: issuedAt,
      nonce: nonceText,
      ciphertext: cipherText,
      mac: macText,
    );
    return {
      'e2ee': {
        'v': version,
        'alg': 'AES-256-GCM',
        'aad': aadText,
        'eventId': eventId,
        'issuedAt': issuedAt,
        'signerDeviceId': deviceId,
        'nonce': nonceText,
        'ciphertext': cipherText,
        'mac': macText,
        'sigAlg': 'HMAC-SHA256/account-key/v1',
        'signature': signature,
      },
    };
  }

  static Future<Map<String, dynamic>> decryptPayload({
    required Map<String, dynamic> encryptedPayload,
    required String accountEncryptionKey,
    required String eventType,
    String accountId = '',
    String deviceId = '',
    DateTime? createdAt,
  }) async {
    final e2eeRaw = encryptedPayload['e2ee'];
    if (e2eeRaw is! Map) return encryptedPayload;
    final e2ee = Map<String, dynamic>.from(e2eeRaw);
    final payloadVersion = e2ee['v'];
    if (payloadVersion != version && payloadVersion != legacyVersion) {
      throw StateError('Неподдерживаемая версия E2E payload: $payloadVersion');
    }
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final nonce = _decodeBase64UrlNoPadding(e2ee['nonce']?.toString() ?? '');
    final cipherText = _decodeBase64UrlNoPadding(e2ee['ciphertext']?.toString() ?? '');
    final mac = _decodeBase64UrlNoPadding(e2ee['mac']?.toString() ?? '');

    if (payloadVersion == version) {
      final eventId = e2ee['eventId']?.toString() ?? '';
      final issuedAt = e2ee['issuedAt']?.toString() ?? '';
      final signerDeviceId = e2ee['signerDeviceId']?.toString() ?? deviceId;
      final expected = _signEnvelope(
        keyBytes: keyBytes,
        accountId: accountId,
        deviceId: signerDeviceId,
        eventType: eventType,
        eventId: eventId,
        issuedAt: issuedAt,
        nonce: e2ee['nonce']?.toString() ?? '',
        ciphertext: e2ee['ciphertext']?.toString() ?? '',
        mac: e2ee['mac']?.toString() ?? '',
      );
      final actual = e2ee['signature']?.toString() ?? '';
      if (!_constantTimeStringEquals(expected, actual)) {
        throw StateError('Подпись sync-события не прошла проверку');
      }
      final clearText = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(keyBytes),
        aad: utf8.encode(_aadText(eventType, accountId, signerDeviceId, eventId, issuedAt)),
      );
      final decoded = jsonDecode(utf8.decode(clearText));
      if (decoded is! Map) throw StateError('E2E payload is not a JSON object');
      return Map<String, dynamic>.from(decoded);
    }

    // Backward compatibility with v1 clients during rolling updates.
    final clearText = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(keyBytes),
      aad: utf8.encode(eventType),
    );
    final decoded = jsonDecode(utf8.decode(clearText));
    if (decoded is! Map) throw StateError('E2E payload is not a JSON object');
    return Map<String, dynamic>.from(decoded);
  }


  static Future<BinaryEncryptionResult> encryptBinaryFrame({
    required Map<String, dynamic> headerFields,
    required List<int> clearBytes,
    required String accountEncryptionKey,
  }) async {
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final header = Map<String, dynamic>.from(headerFields);
    final eventType = header['type']?.toString() ?? 'binary';
    final accountId = header['accountId']?.toString() ?? '';
    final deviceId = header['deviceId']?.toString() ?? '';
    final eventId = _base64UrlNoPadding(_randomBytes(16));
    final issuedAt = DateTime.now().toUtc().toIso8601String();
    final nonce = _randomBytes(12);
    final aadText = _binaryAadText(header, eventId, issuedAt);
    final secretBox = await _algorithm.encrypt(
      clearBytes,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: utf8.encode(aadText),
    );
    final nonceText = _base64UrlNoPadding(secretBox.nonce);
    final macText = _base64UrlNoPadding(secretBox.mac.bytes);
    final signature = _signBinaryFrame(
      keyBytes: keyBytes,
      accountId: accountId,
      deviceId: deviceId,
      eventType: eventType,
      eventId: eventId,
      issuedAt: issuedAt,
      nonce: nonceText,
      mac: macText,
      aadText: aadText,
    );
    header['e2ee'] = {
      'v': 'readanywhere-binary-e2e-v1',
      'alg': 'AES-256-GCM',
      'eventId': eventId,
      'issuedAt': issuedAt,
      'signerDeviceId': deviceId,
      'nonce': nonceText,
      'mac': macText,
      'sigAlg': 'HMAC-SHA256/account-key/v1',
      'signature': signature,
    };
    return BinaryEncryptionResult(
      header: header,
      cipherBytes: Uint8List.fromList(secretBox.cipherText),
    );
  }

  static Future<Uint8List> decryptBinaryFrame({
    required Map<String, dynamic> header,
    required List<int> cipherBytes,
    required String accountEncryptionKey,
  }) async {
    final e2eeRaw = header['e2ee'];
    if (e2eeRaw is! Map) throw StateError('Binary frame is not encrypted');
    final e2ee = Map<String, dynamic>.from(e2eeRaw);
    if (e2ee['v'] != 'readanywhere-binary-e2e-v1') {
      throw StateError('Неподдерживаемая версия binary E2E: ${e2ee['v']}');
    }
    final keyBytes = _decodeBase64UrlNoPadding(accountEncryptionKey);
    if (keyBytes.length != 32) {
      throw StateError('Некорректный account encryption key: ${keyBytes.length} bytes');
    }
    final eventType = header['type']?.toString() ?? 'binary';
    final accountId = header['accountId']?.toString() ?? '';
    final signerDeviceId = e2ee['signerDeviceId']?.toString() ?? header['deviceId']?.toString() ?? '';
    final eventId = e2ee['eventId']?.toString() ?? '';
    final issuedAt = e2ee['issuedAt']?.toString() ?? '';
    final nonceText = e2ee['nonce']?.toString() ?? '';
    final macText = e2ee['mac']?.toString() ?? '';
    final aadHeader = Map<String, dynamic>.from(header)..remove('e2ee');
    final aadText = _binaryAadText(aadHeader, eventId, issuedAt);
    final expected = _signBinaryFrame(
      keyBytes: keyBytes,
      accountId: accountId,
      deviceId: signerDeviceId,
      eventType: eventType,
      eventId: eventId,
      issuedAt: issuedAt,
      nonce: nonceText,
      mac: macText,
      aadText: aadText,
    );
    final actual = e2ee['signature']?.toString() ?? '';
    if (!_constantTimeStringEquals(expected, actual)) {
      throw StateError('Подпись binary sync-события не прошла проверку');
    }
    final clear = await _algorithm.decrypt(
      SecretBox(
        cipherBytes,
        nonce: _decodeBase64UrlNoPadding(nonceText),
        mac: Mac(_decodeBase64UrlNoPadding(macText)),
      ),
      secretKey: SecretKey(keyBytes),
      aad: utf8.encode(aadText),
    );
    return Uint8List.fromList(clear);
  }

  static bool isEncryptedPayload(Map<String, dynamic> payload) => payload['e2ee'] is Map;

  static String? encryptedEventId(Map<String, dynamic> payload) {
    final e2ee = payload['e2ee'];
    if (e2ee is! Map) return null;
    return e2ee['eventId']?.toString();
  }

  static DateTime? encryptedIssuedAt(Map<String, dynamic> payload) {
    final e2ee = payload['e2ee'];
    if (e2ee is! Map) return null;
    return DateTime.tryParse(e2ee['issuedAt']?.toString() ?? '');
  }

  static String? encryptedSignerDeviceId(Map<String, dynamic> payload) {
    final e2ee = payload['e2ee'];
    if (e2ee is! Map) return null;
    return e2ee['signerDeviceId']?.toString();
  }

  static String _aadText(String eventType, String accountId, String deviceId, String eventId, String issuedAt) =>
      'readanywhere|$eventType|$accountId|$deviceId|$eventId|$issuedAt';

  static String _signEnvelope({
    required List<int> keyBytes,
    required String accountId,
    required String deviceId,
    required String eventType,
    required String eventId,
    required String issuedAt,
    required String nonce,
    required String ciphertext,
    required String mac,
  }) {
    final input = [
      version,
      accountId,
      deviceId,
      eventType,
      eventId,
      issuedAt,
      nonce,
      ciphertext,
      mac,
    ].join('\n');
    return _base64UrlNoPadding(crypto.Hmac(crypto.sha256, keyBytes).convert(utf8.encode(input)).bytes);
  }


  static String _binaryAadText(Map<String, dynamic> header, String eventId, String issuedAt) {
    final sanitized = Map<String, dynamic>.from(header)..remove('e2ee');
    return 'readanywhere-binary|$eventId|$issuedAt|${_canonicalJson(sanitized)}';
  }

  static String _signBinaryFrame({
    required List<int> keyBytes,
    required String accountId,
    required String deviceId,
    required String eventType,
    required String eventId,
    required String issuedAt,
    required String nonce,
    required String mac,
    required String aadText,
  }) {
    final input = [
      'readanywhere-binary-e2e-v1',
      accountId,
      deviceId,
      eventType,
      eventId,
      issuedAt,
      nonce,
      mac,
      aadText,
    ].join('\n');
    return _base64UrlNoPadding(crypto.Hmac(crypto.sha256, keyBytes).convert(utf8.encode(input)).bytes);
  }

  static String _canonicalJson(Object? value) {
    Object? normalize(Object? item) {
      if (item is Map) {
        final entries = item.entries.toList()
          ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
        return {for (final entry in entries) entry.key.toString(): normalize(entry.value)};
      }
      if (item is Iterable) return item.map(normalize).toList();
      return item;
    }
    return jsonEncode(normalize(value));
  }

  static bool _constantTimeStringEquals(String a, String b) {
    final aa = utf8.encode(a);
    final bb = utf8.encode(b);
    if (aa.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < aa.length; i++) {
      diff |= aa[i] ^ bb[i];
    }
    return diff == 0;
  }

  static List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _random.nextInt(256));

  static String _base64UrlNoPadding(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

  static List<int> _decodeBase64UrlNoPadding(String raw) {
    final normalized = raw.trim();
    final padded = normalized + ('=' * ((4 - normalized.length % 4) % 4));
    return base64Url.decode(padded);
  }
}
