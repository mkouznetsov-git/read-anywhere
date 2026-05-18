# Sprint 42A Hotfix 13 — file_picker API rollback + compileSdk 36

## Причина

Hotfix 12 правильно поднял Android `compileSdk` до 36, но одновременно обновил `file_picker` до 11.x.
В текущем Flutter/Dart окружении CI это сломало compile smoke test: `FilePicker.platform` больше не находился на этапе компиляции.

## Решение

- `file_picker` возвращён на стабильную ветку `^8.3.7`, которая уже использовалась в проекте и совместима с текущим кодом `BookImportService`.
- Патч `compileSdk = 36` в `scripts/prepare_flutter_platforms.sh` сохранён.
- Установка Android SDK platform 36 в CI сохранена.
- Исправление импорта FB2 на Android сохранено: на Android picker открывается как `FileType.any`, а расширение проверяется уже после выбора файла.

## Что не менялось

- DOCX renderer.
- EPUB anchors.
- Library guard.
- Relay.
- PDF / DJVU / FB2 / TXT readers.

## Relay

Relay через SSH обновлять не нужно.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter build apk --release
flutter build macos --release
```

В GitHub Actions тесты должны пройти дальше ошибки:

```text
Error: Member not found: 'platform'.
final result = await FilePicker.platform.pickFiles(
```
