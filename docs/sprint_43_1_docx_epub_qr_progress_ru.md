# Sprint 43.1 — DOCX polish, EPUB anchors, QR scanner, progress scrub overlay

## Цель

Довести Sprint 43 без смены серверной архитектуры: отполировать DOCX-страницу до эталонного вида, стабилизировать переходы EPUB на длинных книгах, добавить видимый процент при перетаскивании прогресса и сделать QR-сканер на Android диагностируемым.

## Изменения

### DOCX

- Чуть увеличены базовый кегль и межстрочный интервал DOCX.
- Левое/правое поле страницы сделано ближе к эталонному viewer.
- Строка вида `г. Москва ... 9 августа 2022 г.` рендерится как двухколоночная строка: город слева, дата справа.
- Возвращена безопасная нумерация страниц как overlay в правом верхнем углу листа.
- Усилен разбор многоуровневой нумерации:
  - `w:start`;
  - numbering из paragraph style;
  - стабильные счётчики по `numId`/`ilvl`.
- Сохраняется подавление мусорных cached numeric runs из header, чтобы не возвращался артефакт `12 / 1`.

### EPUB

- Внутренний переход теперь сначала фактически двигает viewport к target unit и только после этого сохраняет progress/locator.
- Это закрывает сценарий, когда progress bar показывал правильную процентовку для главы, а экран оставался на старом месте и сбрасывал progress после микроскролла.
- Exact `path#fragment` targets могут обновляться до ближайшего видимого блока, а path-only fallback остаётся первым стабильным входом в XHTML.

Проверочный файл: `Patton_Dzh_-_Polzovatelskie_istorii_Iskusstvo_gibkoy_razrabotki_PO_-_2017.epub`, переход `Глава 16. Огранка, полировка, разработка`.

### Progress scrub overlay

- Для непрерывного reader progress bar добавлен bubble с текущим процентом над полосой при drag/active scrub.
- Работает для мыши на desktop и для активного drag на Android.

### Android QR scanner

- Заголовок экрана сокращён до `Сканировать QR`.
- `MobileScannerController` переведён в `noDuplicates`.
- Добавлен fallback UI с конкретным текстом ошибки и кнопкой `Ввести код вручную`.
- Android manifest уже получает `CAMERA` permission через `prepare_flutter_platforms.sh`.

## Relay

Relay через SSH обновлять не нужно.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build macos --release
```

## Ручная проверка

1. DOCX: открыть `Договор_поставки.docx`, сравнить дату справа, поля, кегль, page number и многоуровневую нумерацию.
2. EPUB: открыть книгу Patton, перейти на `Глава 16. Огранка, полировка, разработка`, проверить, что экран и progress совпадают и не сбиваются после микроскролла.
3. Progress: потянуть нижнюю полосу и проверить bubble с процентом.
4. Android: открыть `Сканировать QR`; при сбое камеры должна быть понятная ошибка и ручной fallback.
