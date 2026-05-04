# Sprint 4.1 Cleanup 01 — уменьшение размера сборок

## Цель

Перестать публиковать debug-сборки как основной результат CI и перейти на release-артефакты.

## Что изменено

### Android

Скрипт `scripts/package_android.sh` теперь собирает:

- release APK отдельно по ABI:
  - `ReadAnywhere-<version>-android-arm64-v8a-release.apk`
  - `ReadAnywhere-<version>-android-armeabi-v7a-release.apk`
  - `ReadAnywhere-<version>-android-x86_64-release.apk`
- release App Bundle:
  - `ReadAnywhere-<version>-android-release.aab`
- `SHA256SUMS` для проверки целостности.

Debug APK больше не собирается по умолчанию. Его можно включить вручную через параметр GitHub Actions `build_debug_artifacts=true`.

### macOS

Скрипт `scripts/package_macos.sh` собирает только release-приложение:

- `ReadAnywhere-<version>-macos-release.dmg`
- `ReadAnywhere-<version>-macos-release.pkg`
- `ReadAnywhere-<version>-macos-release-app.zip`
- `SHA256SUMS`.

Debug app zip можно включить только вручную через `build_debug_artifacts=true`.

### GitHub Actions

Workflow теперь называется так же, но jobs переименованы:

- `Flutter and relay tests`
- `Android release APKs and AAB`
- `macOS release DMG and PKG`

Порядок остался безопасным:

```text
tests → android release
      → macOS release
```

## Как запустить обычную release-сборку

GitHub → Actions → Build installable packages → Run workflow.

Параметр `build_debug_artifacts` оставить `false`.

## Как собрать debug-артефакты при необходимости

GitHub → Actions → Build installable packages → Run workflow:

```text
build_debug_artifacts = true
```

## Локальный запуск

Android release:

```bash
./scripts/package_android.sh
```

macOS release:

```bash
./scripts/package_macos.sh
```

Опционально с debug-артефактами:

```bash
BUILD_DEBUG_ARTIFACTS=true ./scripts/package_android.sh
BUILD_DEBUG_ARTIFACTS=true ./scripts/package_macos.sh
```

## Что ожидать по размеру

Android должен стать заметно меньше, потому что вместо одного большого debug APK теперь создаются отдельные release APK под конкретную архитектуру.

macOS уже собирался в release-режиме в предыдущем спринте, поэтому сильного уменьшения может не быть. Flutter desktop-приложение всё равно включает Flutter engine и нативные библиотеки, поэтому macOS DMG/PKG не будет весить несколько мегабайт.

## Важное ограничение

Текущие Android release-сборки подходят для внутреннего тестирования. Для публикации в Google Play позже нужно добавить настоящий release keystore и подписывать AAB/APK production-ключом.

macOS DMG/PKG пока unsigned. Для публичной раздачи нужны Developer ID signing и notarization.
