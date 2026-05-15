# Sprint 42A Hotfix 07 — ReadArc naming cleanup

## Цель

Убрать оставшиеся технические имена `ReadArc` из новых классов и пользовательского кода после переименования проекта в ReadArc.

## Изменения

- `ReadArcApp` переименован в `ReadArcApp`.
- `ReadArcTheme` переименован в `ReadArcTheme`.
- `ReadArcE2eCrypto` переименован в `ReadArcE2eCrypto`.
- Новые binary/event headers используют `ReadArc`-имена.
- Каноническая папка данных теперь `ReadArc`.
- Старая папка `ReadArc` остаётся только источником миграции, чтобы не потерять библиотеку после обновления старых сборок.
- Старые pairing-ссылки и wire-протоколы принимаются как legacy compatibility, но новые сущности должны использовать ReadArc-имена.

## Relay

Relay обновлять не нужно для этого hotfix-а, если hotfix 06 уже был задеплоен. Если hotfix 06 ещё не выкатывался, его relay-изменения по `/health` всё ещё требуют деплоя.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build macos --release
```

## Ручная проверка

1. Обновить приложение поверх предыдущей сборки.
2. Проверить, что библиотека не исчезла.
3. Добавить новую книгу и перезапустить приложение.
4. Проверить, что после перезапуска книга остаётся в библиотеке.
