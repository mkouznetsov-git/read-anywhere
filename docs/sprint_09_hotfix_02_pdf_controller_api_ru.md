# Sprint 9 Hotfix 02 — PdfController API

## Исправление

Сборка падала на Android и macOS из-за вызова несуществующего метода `PdfController.jumpTo(...)` в `pdfx 2.9.2`.

Исправлено на поддерживаемый API:

```dart
_controller?.jumpToPage(safePage);
```

## Защита от повторения

Добавлен `test/compile_smoke_test.dart`, который импортирует `lib/main.dart`. Теперь `flutter test` компилирует основной модуль приложения и ловит такие ошибки раньше, до Android/macOS packaging jobs.
