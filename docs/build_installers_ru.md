# Сборка ReadArc

## Единый проверяемый pipeline

Workflow `.github/workflows/quality_gate.yml` использует зафиксированные Flutter `3.47.0`, Rust `1.98.0`, `cargo-ndk` `4.1.2` и SHA сторонних GitHub Actions.

Порядок jobs жёсткий:

1. unit/regression/static checks;
2. Android emulator smoke, macOS application smoke и iOS unsigned build smoke;
3. Android и macOS packaging;
4. GitHub Release только после успеха всех предыдущих jobs.

Платформенные каталоги `android/`, `ios/`, `macos/` закоммичены. CI их валидирует и больше не запускает `flutter create` и не патчит `.pub-cache`.

## Артефакты

Android job создаёт universal APK, APK для `arm64-v8a`, `armeabi-v7a`, `x86_64`, AAB и SHA-256 checksums. Встроенный DJVU engine обязателен для всех публикуемых ABI.

macOS job создаёт `.dmg`, `.pkg`, `.app.zip` и checksums. Это внутренние ad-hoc сборки, пока не подключены Developer ID и notarization.

iOS в Sprint 45 компилируется без подписи как обязательная проверка проекта. Installable IPA не публикуется до подключения Apple signing/provisioning secrets.

## Android signing

Публичный dev keystore больше не используется. Для публикации GitHub Actions нужны защищённые secrets:

- `ANDROID_KEYSTORE_BASE64`;
- `ANDROID_KEYSTORE_PASSWORD`;
- `ANDROID_KEY_ALIAS`;
- `ANDROID_KEY_PASSWORD`.

При push в `main`, теге `v*` или ручной публикации отсутствие любого секрета останавливает packaging и release. Pull request может собрать тестовый package с Android debug key, но такой package не публикуется в Releases.

Для локальной release-сборки создайте untracked `apps/flutter_client/android/key.properties` и положите keystore в `android/app/`. Эти пути исключены из Git.

## Cleartext traffic

Production Android manifest содержит `android:usesCleartextTraffic="false"`. Разрешение HTTP/WS находится только в debug overlay manifest для локальной разработки. Официальный relay по умолчанию: `https://relay.readarc.ru`.

## Локальные команды

Из корня репозитория:

```bash
bash ./scripts/quality_gate.sh
bash ./scripts/package_android.sh
bash ./scripts/package_macos.sh
```

Параметр `BUILD_DEBUG_ARTIFACTS=true` дополнительно создаёт debug-артефакты. `READARC_DEFAULT_RELAY_URL` можно задать для диагностической сборки; обычная сборка использует официальный relay.
