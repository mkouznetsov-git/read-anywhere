# ReadArc Flutter client

Кроссплатформенный клиент ReadArc для Android, iOS и macOS. Платформенные проекты находятся в репозитории и не генерируются во время CI.

## Зафиксированная среда

- Flutter `3.47.0` / Dart `3.13.x`;
- версия Flutter продублирована в `.fvmrc`;
- прямые Dart-зависимости и `pubspec.lock` зафиксированы.

После установки нужной версии Flutter:

```bash
flutter pub get --enforce-lockfile
flutter analyze --fatal-warnings --fatal-infos
flutter test
```

Полная локальная проверка из корня репозитория:

```bash
bash ./scripts/quality_gate.sh
```
