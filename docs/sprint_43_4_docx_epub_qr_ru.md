# Sprint 43.4 — DOCX page fidelity, EPUB link offsets, QR scanner rollback

## Цель

Закрыть замечания после Sprint 43.3 без изменения relay: сохранить явные пустые строки DOCX, убрать «лесенку» абзацев, точнее соблюдать Word page breaks, стабилизировать переходы EPUB по внутренним ссылкам и вернуть максимально близкий к прежнему рабочему QR scanner.

## DOCX

- Явные page break markers больше не фильтруются до пагинации.
- Автоматическая пагинация стала менее агрессивной, чтобы не начинать новую страницу при большом свободном месте снизу.
- Пустые Word-абзацы сохраняются как визуальный вертикальный интервал.
- Левые/first-line indents больше не применяются напрямую для юридических абзацев, чтобы убрать видимую «лесенку».
- Небольшой gutter оставлен только для сгенерированной нумерации.

## EPUB

- Переход по ссылке теперь использует фактический offset целевого render-unit, а не `maxScrollExtent * progressPercent`.
- Progress/locator после перехода фиксируются по целевому unit, чтобы экран и нижний процент не расходились.
- Cover image получает увеличенную высоту и отображается через `BoxFit.contain`, чтобы не обрезаться по вертикали.

## QR scanner

- Экран сканирования возвращён к прежней controller-based схеме `MobileScannerController + MobileScanner(controller: ...)` без дополнительных wrappers/fit/error-builder.
- `mobile_scanner` закреплён на `6.0.2`, чтобы не получить несовместимое patch/minor-поведение при новом `flutter pub get`.

## Relay

Relay обновлять не нужно.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build macos --release
```
