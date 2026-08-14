import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) => File(relativePath).readAsStringSync();

void main() {
  group('ReadArc regression contracts', () {
    test('project naming never falls back to ReadAnywhere', () {
      final roots = <String>[
        '../../README_RU.md',
        '../../.github/workflows/build_installers.yml',
        '../../scripts/prepare_flutter_platforms.sh',
        'lib/main.dart',
        'pubspec.yaml',
      ];
      final forbidden = RegExp(r'ReadAnywhere|Read Anywhere|readanywhere|read-anywhere|read_anywhere|READANYWHERE');
      final offenders = <String>[];
      for (final path in roots) {
        final file = File(path);
        if (!file.existsSync()) continue;
        if (forbidden.hasMatch(file.readAsStringSync())) offenders.add(path);
      }
      expect(offenders, isEmpty, reason: 'Legacy ReadAnywhere naming returned in: ${offenders.join(', ')}');
    });

    test('QR scanner stays on the known working backend', () {
      final pubspec = _read('pubspec.yaml');
      final main = _read('lib/main.dart');
      expect(pubspec, contains('qr_code_scanner_plus:'));
      expect(main, contains("package:qr_code_scanner_plus/qr_code_scanner_plus.dart"));
      expect(pubspec, isNot(contains('mobile_scanner:')));
      expect(main, isNot(contains("package:mobile_scanner/mobile_scanner.dart")));
    });

    test('Android platform preparation preserves camera and internet permissions', () {
      final script = _read('../../scripts/prepare_flutter_platforms.sh');
      expect(script, contains('android.permission.CAMERA'));
      expect(script, contains('android.permission.INTERNET'));
      expect(script, contains('qr_code_scanner_plus'));
    });

    test('pairing UI remains six-digit-code based', () {
      final main = _read('lib/main.dart');
      expect(main, contains('Создать код подключения'));
      expect(main, contains('Показать QR'));
      expect(main, contains('Введите код приглашения'));
      expect(main, contains('Введите код на подключаемом устройстве'));
    });

    test('library download paths remain guarded by relay connectivity', () {
      final main = _read('lib/main.dart');
      expect(main, contains("if (!widget.sync.state.value.connected)"));
      expect(main, contains('Нет подключения к relay.'));
    });

    test('critical reader routes remain registered', () {
      final main = _read('lib/main.dart');
      for (final extension in ['pdf', 'djvu', 'epub', 'fb2', 'txt', 'docx', 'doc']) {
        expect(main, contains("case '$extension':"), reason: 'Reader route for .$extension disappeared');
      }
    });
  });
}
