# Сборка DMG/PKG/APK для ReadAnywhere

## Короткий ответ

Да, из Flutter-проекта можно сделать:

- `.dmg` для macOS;
- `.pkg` для macOS;
- `.apk` для Android.

Но для сборки нужны SDK и платформенные инструменты:

- macOS-сборка требует macOS + Xcode command line tools;
- Android-сборка требует Android SDK/JDK;
- Flutter SDK нужен в обоих случаях.

Если Flutter не установлен локально, проще всего использовать GitHub Actions. В проект добавлен workflow:

```text
.github/workflows/build_installers.yml
```

Он собирает артефакты на удалённых runner-ах GitHub.

## Как собрать без локальной установки Flutter

1. Создайте новый репозиторий на GitHub.
2. Загрузите туда содержимое папки `read_anywhere_mvp`.
3. Откройте вкладку `Actions`.
4. Выберите workflow `Build installable packages`.
5. Нажмите `Run workflow`.
6. Параметр `build_debug_artifacts` оставьте `false`, если не нужны debug-сборки.
7. После завершения откройте completed run и скачайте `Artifacts`:
   - `ReadAnywhere-android-release`;
   - `ReadAnywhere-macos-release-dmg-pkg`.

## Что именно будет собрано

### Android

По умолчанию собираются release-артефакты для внутреннего тестирования:

```text
dist/android/ReadAnywhere-0.1.0-android-arm64-v8a-release.apk
dist/android/ReadAnywhere-0.1.0-android-armeabi-v7a-release.apk
dist/android/ReadAnywhere-0.1.0-android-x86_64-release.apk
dist/android/ReadAnywhere-0.1.0-android-release.aab
dist/android/SHA256SUMS
```

Для большинства современных телефонов нужен `arm64-v8a`. Для публикации в Google Play позже нужно настроить production keystore и загружать `.aab`.

### macOS

Будут собраны:

```text
dist/macos/ReadAnywhere-0.1.0-macos-release.dmg
dist/macos/ReadAnywhere-0.1.0-macos-release.pkg
dist/macos/ReadAnywhere-0.1.0-macos-release-app.zip
dist/macos/SHA256SUMS
```

Это unsigned-сборки для внутреннего тестирования. Для нормальной публичной раздачи macOS-приложение нужно подписать Developer ID certificate и notarize у Apple.

## Локальная сборка на macOS

Если Flutter всё-таки установлен:

```bash
./scripts/package_macos.sh
./scripts/package_android.sh
```

Debug-артефакты можно дополнительно собрать так:

```bash
BUILD_DEBUG_ARTIFACTS=true ./scripts/package_macos.sh
BUILD_DEBUG_ARTIFACTS=true ./scripts/package_android.sh
```

## Production signing: Android

Для production Android нужно:

1. Создать keystore.
2. Добавить `android/key.properties`.
3. Настроить signingConfig в `android/app/build.gradle`.
4. Запустить:

```bash
flutter build appbundle --release
```

Google Play обычно принимает `.aab`; `.apk` удобен для ручной установки и внутреннего тестирования.

## Production signing: macOS

Для production macOS нужно:

1. Apple Developer Program.
2. Developer ID Application certificate.
3. Подпись `.app`.
4. Создание `.dmg` или `.pkg`.
5. Notarization.
6. Stapling notarization ticket.

Без этого macOS может показывать предупреждение Gatekeeper при открытии скачанного приложения.

## Важное ограничение текущего MVP

Текущий архив — исходный MVP, а не готовая production-сборка. Workflow сначала генерирует недостающие платформенные папки Flutter (`android/`, `macos/`) через `flutter create`, затем собирает пакеты.

## Тесты в GitHub Actions

Перед упаковкой APK/DMG/PKG workflow запускает job `Flutter and relay tests`.

Если `flutter test` или проверка relay-сервера падает, jobs сборки не стартуют и installable artifacts не публикуются. Локально тот же набор проверок можно запустить так:

```bash
./scripts/run_tests.sh
```

## Сборка с endpoint по умолчанию

Если relay уже развёрнут, например на Koyeb, можно встроить его URL в приложение:

```bash
READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh
READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_macos.sh
```

В GitHub Actions есть два варианта:

1. При ручном запуске workflow заполнить input `default_relay_url`.
2. Создать repository variable `READANYWHERE_DEFAULT_RELAY_URL`.

После этого в приложении можно выбрать режим **ReadAnywhere relay** вместо ручного ввода URL.

## Публикация через GitHub Releases

Artifacts из workflow остаются удобными для CI-проверки, но для скачивания тестовых сборок лучше использовать GitHub Releases. Workflow автоматически создаёт релиз, когда в репозиторий отправляется тег вида `v*`.

Пример:

```bash
git tag v0.1.0-test
git push origin v0.1.0-test
```

После завершения workflow откройте:

```text
Repository → Releases → v0.1.0-test
```

Там будут APK/AAB/DMG/PKG/ZIP и checksum-файлы. Если релиз для этого тега уже существует, workflow обновит файлы с `--clobber`.
