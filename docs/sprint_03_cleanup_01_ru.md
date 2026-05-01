# Sprint 3 cleanup 01: название приложения и тесты в CI

## Что изменено

1. Пользовательское название приложения закреплено как `ReadAnywhere`:
   - Flutter `MaterialApp.title`;
   - заголовок главного экрана;
   - macOS `CFBundleName` / `CFBundleDisplayName` при генерации platform-folder;
   - Android launcher label при генерации `AndroidManifest.xml`;
   - имена DMG/PKG/APK artifacts уже используют `ReadAnywhere`.

2. В GitHub Actions добавлен обязательный job `Flutter and relay tests`.

3. Сборка Android и macOS теперь зависит от успешного прохождения тестов:

```text
Flutter and relay tests -> Android APK
Flutter and relay tests -> macOS DMG and PKG
```

4. Добавлен локальный скрипт:

```bash
./scripts/run_tests.sh
```

Он выполняет:

```bash
flutter pub get
flutter test
python3 -m py_compile server/rendezvous_relay/main.py
```

5. На экране синхронизации добавлена более заметная подсказка про `accountId`: все устройства одного аккаунта должны использовать одинаковый `accountId`.

## Как проверить

1. Залейте изменения в GitHub.
2. Откройте Actions.
3. Запустите `Build installable packages`.
4. Сначала должен пройти job `Flutter and relay tests`.
5. Только после этого начнутся jobs `Android APK` и `macOS DMG and PKG`.

Если тесты упадут, APK/DMG/PKG не будут собраны.
