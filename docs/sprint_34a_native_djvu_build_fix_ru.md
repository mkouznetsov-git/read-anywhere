# Sprint 34a — compile fix для embedded DJVU engine

## Что исправлено

1. Android native build больше не запускает `cargo-ndk` из `apps/flutter_client`. Скрипт переходит в каталог Rust crate `native/readarc_engines/djvu`, поэтому `cargo metadata` видит правильный `Cargo.toml`.
2. Rust DJVU bridge переведён с ручного `DjVuDocument<'static>` на owned `djvu_rs::Document::from_bytes(...)`.
3. Рендер страницы использует публичный API `page.render_to_size(width, height)` вместо устаревшего/ошибочного поля `RenderOptions.dpi`.
4. Версия Flutter-клиента обновлена до `0.1.0+35`.

## Relay

Relay обновлять не нужно. Серверный код не менялся.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter analyze
```

Для release jobs нужно проверить, что в логах больше нет ошибок:

```text
could not find Cargo.toml in apps/flutter_client
struct takes 0 lifetime arguments
RenderOptions has no field named dpi
```

## Ручная проверка

1. Собрать Android и macOS release через GitHub Actions.
2. Проверить, что native DJVU library попала в app/APK.
3. Открыть DJVU на Mac и Android: страницы должны рендериться через embedded engine, без `brew`, `ddjvu`, `djvused`, `djvutxt`.
4. Открыть PDF: постраничный режим остаётся основным режимом чтения.
