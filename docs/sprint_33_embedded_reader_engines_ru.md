# Sprint 33 — Embedded reader engines

## Цель

Развернуть форматный слой ReadArc от внешних утилит к встроенным reader engines.

## Что изменено

1. DJVU больше не запускает внешние `ddjvu`, `djvused`, `djvutxt` из runtime-пути.
2. Добавлен pure-Dart DJVU container probe для безопасного определения формата и
   количества страниц без shell-команд.
3. Добавлена native/Rust engine scaffold-структура `native/readarc_engines/`.
4. Зафиксировано решение использовать MIT `djvu-rs`, а не GPL DjVuLibre.
5. Для больших PDF включён экономный single-page mode: рендерится одна страница,
   что должно предотвращать зависание интерфейса на 30+ МБ файлах.
6. Версия клиента обновлена до `0.1.0+33`.

## Ограничение Sprint 33

В Sprint 33 выбран и заложен embedded DJVU path, но полноэкранный native renderer
ещё не связан с Flutter binary на всех платформах. Важно: внешний backend уже
убран, но полноценный render-page ABI нужно довести следующим шагом через Rust FFI.

## Relay

Relay обновлять не нужно. Серверный код не менялся.

## Проверка

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter analyze
```

Ручная проверка:

1. Открыть DJVU на Mac: приложение не должно закрыться и не должно требовать
   `brew install djvulibre`.
2. Открыть CHM: приложение не должно закрыться.
3. Открыть PDF 34 МБ на Mac и Android: должен включиться экономный режим, где
   отображается одна страница и кнопки Назад/Вперёд.
4. Проверить, что обычные PDF всё ещё открываются как continuous fit-width reader.
