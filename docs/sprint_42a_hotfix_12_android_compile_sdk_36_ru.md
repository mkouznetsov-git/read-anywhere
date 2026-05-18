# Sprint 42A Hotfix 12 — Android compileSdk 36 / file_picker update

## Причина

Android release build падал на задаче `:file_picker:checkReleaseAarMetadata`.
Новая цепочка зависимостей Flutter/AndroidX требует сборку Android-плагинов с `compileSdk >= 36`, а прежний `file_picker` подтягивался как версия 8.x и компилировался против `android-34`.

## Изменения

- `file_picker` обновлён с `^8.1.2` до `^11.0.2`.
- `scripts/prepare_flutter_platforms.sh` после `flutter create`:
  - устанавливает `platforms;android-36`, если доступен `sdkmanager`;
  - нормализует generated `android/app/build.gradle.kts` до `compileSdk = 36`.

## Что не менялось

- Relay не менялся.
- DOCX renderer не менялся.
- EPUB fixes и library guard из Hotfix 11 сохранены.
- PDF / DJVU / FB2 / TXT не менялись.

## Проверка

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

В GitHub Actions Android job должен пройти дальше места `:file_picker:checkReleaseAarMetadata`.
