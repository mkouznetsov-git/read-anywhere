# Sprint 43.8 — QR scanner backend rollback/replacement

## Цель

Починить Android QR scanner без изменения DOCX/EPUB/sync-кода.

## Что изменено

- Проведён diff последней рабочей реализации QR scanner-а и текущей реализации.
- Dart-экран `MobileScanner` действительно почти совпадал со старым рабочим кодом, поэтому причина оказалась не в содержимом QR-кода и не в тексте приглашения.
- Основной подозрительный фактор: нативный Android backend `mobile_scanner` / CameraX / MLKit на текущем generated Android окружении.
- QR scanner переведён с `mobile_scanner` на `qr_code_scanner_plus`, который использует другой Android backend — ZXing через embedded platform view.
- Поведение снаружи сохранено: экран возвращает строку QR, а основной код берёт из неё только 6 цифр подключения.
- Кнопка ручного ввода сохранена.

## Что специально не менялось

- DOCX reader.
- EPUB reader.
- Sync.
- Relay.
- Packaging, кроме точечной нормализации Android compileSdk для QR plugin-а.

## Relay

Обновлять relay через SSH не нужно.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build macos --release
```

## Regression checklist

- QR должен по-прежнему подставлять только 6-значный код подключения.
- QR не должен возвращать длинную `readarc://...` строку в поле ввода.
- Кнопка `Ввести код вручную` должна оставаться доступной.
- Синхронизация, DOCX, EPUB, FB2/PDF/DJVU/TXT и packaging не должны измениться этим спринтом.
