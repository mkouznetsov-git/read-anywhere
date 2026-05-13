# Sprint 34 — постраничный PDF и встроенный DJVU engine

## Цели

1. Сделать постраничный PDF единственным рабочим режимом чтения.
2. Убрать предупреждение про «большой PDF» — для пользователя это теперь обычный режим ReadArc.
3. Исправить размытый PDF на Android: рендер страниц теперь выполняется с повышенным devicePixelRatio и ограниченным page-cache.
4. Сохранить возможность выделения/копирования текста PDF через отдельный текстовый слой.
5. Довести DJVU до embedded-engine архитектуры: без Homebrew, без `ddjvu`, без внешних утилит и без серверной конвертации.

## PDF

Изменения:

- continuous PDF list отключён;
- любой PDF открывается как одна страница с навигацией «Назад / Вперёд»;
- Android больше не зажимается до DPR 1.0;
- render limit повышен до 2600×3900 на Android;
- page cache уменьшен до 2 страниц на Android и 3 страниц на desktop;
- extraction текстового слоя вынесен в background isolate через `compute()`.

Ожидаемый результат:

- PDF 34 МБ не подвешивает UI при открытии;
- текст на Android должен быть заметно чётче;
- кнопки «Показать текстовый слой» и «Копировать текст PDF» остаются доступными, если в PDF есть извлекаемый текст.

## DJVU

Изменения:

- добавлен Dart FFI bridge `DjvuEmbeddedEngine`;
- добавлен Rust native engine scaffold `readarc_djvu_engine`;
- runtime больше не вызывает `ddjvu`, `djvused`, `djvutxt`;
- GitHub Actions release jobs подготавливают Rust toolchain;
- Android packaging пытается собрать и вложить `libreadarc_djvu_engine.so` для `arm64-v8a`;
- macOS packaging пытается собрать и вложить `libreadarc_djvu_engine.dylib` в `.app/Contents/Frameworks`.

Важное ограничение:

- если native engine не собрался или не вошёл в пакет, DJVU reader не закрывает приложение, а показывает диагностическое сообщение на странице;
- следующий контрольный пункт — проверить GitHub Actions native build и при необходимости добить Rust API compatibility с фактической версией `djvu-rs`.

## Relay

Relay обновлять не нужно. Серверный код не менялся.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter analyze
```

Для release jobs дополнительно проверить, что в логах есть:

```text
Building embedded DJVU engine for Android arm64-v8a...
Building embedded DJVU engine for macOS...
```

## Ручная проверка

1. Открыть PDF 34 МБ на Mac — должен открываться постранично и без предупреждения.
2. Открыть тот же PDF на Android — текст должен быть чётким, не размытым.
3. Проверить переключение в текстовый слой PDF и копирование текста.
4. Открыть DJVU на Mac.
5. Открыть DJVU на Android arm64.
6. Если вместо страницы показана диагностика — смотреть logs GitHub Actions по сборке `readarc_djvu_engine`.
