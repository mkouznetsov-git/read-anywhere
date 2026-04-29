# Сборка DMG/PKG/APK для Read anywhere

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
6. После завершения откройте completed run и скачайте `Artifacts`:
   - `ReadAnywhere-android-apk`;
   - `ReadAnywhere-macos-dmg-pkg`.

## Что именно будет собрано

### Android

По умолчанию собирается debug APK:

```text
dist/android/ReadAnywhere-0.1.0-debug.apk
```

Этот файл можно установить на Android-устройство для тестирования. Для публикации в Google Play нужен release `.aab` или release `.apk`, подписанный вашим keystore.

### macOS

Будут собраны:

```text
dist/macos/ReadAnywhere-0.1.0-macos.dmg
dist/macos/ReadAnywhere-0.1.0-macos.pkg
dist/macos/ReadAnywhere-0.1.0-macos-app.zip
```

Это unsigned-сборки для внутреннего тестирования. Для нормальной публичной раздачи macOS-приложение нужно подписать Developer ID certificate и notarize у Apple.

## Локальная сборка на macOS

Если Flutter всё-таки установлен:

```bash
./scripts/package_macos.sh
./scripts/package_android.sh
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
