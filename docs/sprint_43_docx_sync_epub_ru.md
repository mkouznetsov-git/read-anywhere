# Sprint 43 — DOCX Pro, Sync v2 guard, EPUB links

## Цели

1. Продвинуть DOCX viewer от «похож на документ» к более близкому Word/Pages отображению.
2. Сделать синхронизацию local-first и запретить незаметное обнуление библиотеки.
3. Вернуть и стабилизировать внутренние ссылки EPUB, включая тестовый EPUB с переходом «Благодарности».

## DOCX

В Sprint 43 доработан текущий native DOCX page renderer:

- физическая модель страницы перенастроена под Word/Pages-подобные пропорции;
- увеличены базовый кегль и межстрочный интервал;
- расчёт высоты блоков сделан консервативнее, чтобы на страницу не попадало слишком много текста;
- footer теперь прижат к нижней части фиксированного листа;
- добавлена дедупликация header/footer-блоков;
- числовые cached-runs из header больше не выводятся как `12` / `1` поверх страницы;
- добавлен первичный разбор `word/numbering.xml`;
- поддержаны `abstractNum`, `numId`, `ilvl`, `lvlText`, `numFmt`;
- numbered paragraphs теперь получают префиксы вроде `1.1`, а не превращаются в обычные bullet-пункты.

Это всё ещё не полный Word layout engine, но это уже следующий профессиональный шаг в native DOCX path. WebView/DOCX-to-HTML pipeline оставлен как следующий тяжёлый вариант, если после этого этапа точности окажется недостаточно.

## Sync v2 guard

Синхронизация переведена ближе к local-first модели:

- периодический metadata loop больше не запрашивает snapshot каждые 15 секунд;
- periodic loop теперь только подтягивает offline queue;
- snapshot-запросы остаются на connect/retry/guard-сценариях;
- echo собственного snapshot игнорируется;
- `StorageService.saveManifest()` получил hard guard: непустая локальная библиотека не перезаписывается пустой/укороченной destructive-кандидатурой;
- rejected destructive manifest сохраняется в `manifest_rejected/` для диагностики;
- `_handleLibrarySnapshot()` после merge перечитывает фактически сохранённый manifest, чтобы UI не показывал состояние, которое guard отказался сохранять.

## EPUB

- generated TOC/nav XHTML больше не удаляется полностью;
- TOC отображается компактно: headings/list entries вместо сплошного дампа навигационной страницы;
- кликабельные `href` внутри TOC сохраняются;
- resolver уже поддерживает `path#fragment`, `path`, `#fragment`, decoded variants;
- для книги `Patton_Dzh_-_Polzovatelskie_istorii...epub` переход «Благодарности» должен вести к `index_split_169.xhtml`.

## Relay

Relay через SSH обновлять не нужно. Изменения клиентские.

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

1. DOCX: открыть договор и сравнить с эталоном по шапке, кеглю, нумерации, page/footer.
2. EPUB: открыть приложенную книгу, перейти по «Благодарности», проверить кликабельность внутренних ссылок.
3. Sync: подключить устройства, открыть книгу, вернуться в библиотеку, добавить книгу; библиотека не должна исчезать.
