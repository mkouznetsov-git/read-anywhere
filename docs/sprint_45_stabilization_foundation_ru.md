# Sprint 45 — Stabilization Foundation

## Цель

Сделать сборку ReadArc воспроизводимой и запретить публикацию артефактов, которые не прошли обязательные автоматические проверки. Поведение PDF, DJVU, EPUB, FB2, TXT, DOC и DOCX reader-ов в спринте не меняется.

## Выполнено

- Flutter закреплён на `3.47.0`, Dart — на совместимом диапазоне `3.13.x`.
- Прямые Flutter-зависимости имеют точные версии; `pubspec.lock` закоммичен и CI использует `--enforce-lockfile`.
- Rust закреплён на `1.98.0`, native зависимости — через точные версии и `Cargo.lock`.
- Android, iOS и macOS platform projects созданы один раз и добавлены в Git.
- Удалена CI-регенерация `flutter create`, runtime-патчи plugin Gradle и запись в `.pub-cache`.
- Production Android cleartext отключён; HTTP/WS оставлен только в debug overlay.
- Удалён публичный dev keystore. Release signing загружается только из GitHub Secrets и проверяется по fail-closed правилу.
- Native DJVU engine обязателен в verified packages и собирается для трёх Android ABI и universal macOS.
- Два независимых workflows объединены в один dependency graph: quality → platform smoke → package → release.
- Сторонние GitHub Actions закреплены по commit SHA.
- Все 57 исходных analyzer issues устранены; warnings и infos теперь fatal.
- Dart-код приведён к единому формату с `page_width: 120`; formatting check стал частью quality gate.
- Добавлена обязательная iOS build-smoke проверка, чтобы iOS не выпадал из production-пути.

## Required checks для `main`

После первого запуска workflow защита `main` должна требовать:

- `Unit, regression and static checks`;
- `Android emulator smoke test`;
- `macOS application smoke test`;
- `iOS unsigned build smoke test`.

Прямые push в `main` запрещаются; merge допускается только через актуальный pull request с успешными checks.

## Ручная приёмка

После зелёного CI установить Android APK поверх предыдущей тестовой версии и проверить сохранение библиотеки. На macOS открыть DMG/PKG и проверить импорт и открытие по одному небольшому TXT, EPUB, FB2, DOCX, PDF и DJVU. Для iOS до появления signing secrets достаточно результата build-smoke.

## Relay

Relay protocol, сервер и deployment не менялись. Обновление `https://relay.readarc.ru` для Sprint 45 не требуется.
