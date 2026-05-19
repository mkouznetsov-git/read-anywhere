# Sprint 42A Hotfix 14 — Android plugin compileSdk 36

## Причина

Android build падал на `:file_picker:checkReleaseAarMetadata`: приложение уже переводилось на `compileSdk = 36`, но сам Android-модуль plugin-а `file_picker` оставался с собственным `compileSdk 34`.

## Исправление

`prepare_flutter_platforms.sh` после `flutter pub get` теперь читает `.dart_tool/package_config.json` и нормализует `compileSdk` до `36` в Android Gradle-файлах подключённых Flutter plugin-ов. `targetSdk` и `minSdk` не меняются.

Также удалён неиспользуемый Rust import из embedded DJVU engine, чтобы не засорять CI warning-ами.

## Relay

Relay обновлять не нужно.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter test
flutter build apk --release
```

GitHub Actions должен пройти дальше `:file_picker:checkReleaseAarMetadata`.
