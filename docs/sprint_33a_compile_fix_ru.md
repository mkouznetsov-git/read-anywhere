# Sprint 33a — compile fix for embedded reader engines

## Что исправлено

GitHub Actions падал на компиляции Flutter-клиента:

```text
lib/main.dart:4292:21: Error: No named parameter with the name 'key'.
```

Причина: `_PdfFitWidthPage` использовался с `key: ValueKey(...)`, но constructor этого StatefulWidget не принимал `super.key`.

Исправление:

```dart
const _PdfFitWidthPage({
  super.key,
  required this.document,
  required this.pageNumber,
  required this.displayWidth,
  required this.displayHeight,
  required this.devicePixelRatio,
});
```

Также версия Flutter-клиента обновлена до `0.1.0+34`.

## Relay

Relay обновлять не нужно. Серверный код не менялся.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter analyze
```

## Ручная проверка

1. Открыть большой PDF-файл, например около 34 МБ, на macOS.
2. Проверить, что включается экономный page-by-page режим и приложение не зависает на старте.
3. Повторить на Android.
4. Открыть DJVU/CHM и убедиться, что приложение не просит внешние `ddjvu/djvused/djvutxt`.
