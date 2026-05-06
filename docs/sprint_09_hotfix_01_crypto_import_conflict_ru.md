# Sprint 9 Hotfix 01 — исправление конфликта импортов HMAC

## Проблема

CI падал на загрузке `e2e_crypto_test.dart` с ошибкой:

```text
'Hmac' is imported from both 'package:crypto/src/hmac.dart' and 'package:cryptography/src/cryptography/algorithms.dart'
```

Причина: пакеты `crypto` и `cryptography` оба экспортируют символ `Hmac`.

## Исправление

Импорт `package:crypto/crypto.dart` переведён на namespace alias:

```dart
import 'package:crypto/crypto.dart' as crypto;
```

Подпись envelope теперь создаётся так:

```dart
crypto.Hmac(crypto.sha256, keyBytes)
```

Это не меняет формат подписи, ключи, payload или протокол E2E. Исправление затрагивает только неоднозначность имён в Dart analyzer/compiler.

## Проверка

После push GitHub Actions должен пройти тест `e2e_crypto_test.dart` и продолжить Android/macOS release-сборки.
