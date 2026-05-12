# Sprint 24a — исправление компиляции

Дата: 2026-05-12

## Что исправлено

1. В `_parseFb2Document()` объявлен `imageBudgetBytes`, который использовался при ограничении объёма встроенных FB2-изображений.
2. В PDF text-layer extractor заменён вызов `ZLibDecoder().convert(...)`, несовместимый с текущей версией `archive`, на `ZLibCodec().decode(...)` из `dart:io`.

## Проверка

После распаковки:

```bash
cd apps/flutter_client
flutter clean
flutter pub get
flutter analyze
flutter test
```
