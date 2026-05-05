# ReadAnywhere — MVP starter kit

Цель проекта: приложение для чтения книг на Android, iOS, macOS, Windows и Linux с локальным хранением книг и синхронизацией прогресса/закладок между устройствами без сторонних облачных хранилищ.

Этот репозиторий — стартовый каркас, а не законченный production-reader. Он содержит:

- `apps/flutter_client` — кроссплатформенный Flutter-клиент: библиотека, импорт книг, локальный manifest, прогресс чтения, базовый TXT-reader, заготовки синхронизации.
- `server/rendezvous_relay` — опциональный самохостируемый relay/signaling-сервис на FastAPI WebSocket. Он не пишет данные на диск и не хранит книги; только пересылает зашифрованные сообщения между онлайн-устройствами одного аккаунта.
- `docs` — архитектура, план реализации, тест-план и решения по синхронизации.

## Быстрый запуск клиента

```bash
cd apps/flutter_client
flutter pub get
flutter run -d linux     # или macos/windows/android/ios
```

Перед сборкой под desktop включите нужные платформы:

```bash
flutter config --enable-linux-desktop
flutter config --enable-macos-desktop
flutter config --enable-windows-desktop
```

## Быстрый запуск relay

```bash
cd server/rendezvous_relay
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8787
```

Проверка:

```bash
curl http://127.0.0.1:8787/health
```

## Основные ограничения MVP

1. Полноценный рендеринг PDF/EPUB/DOCX/FB2/DJVU еще не подключен. В коде заложена модель форматов и экраны; TXT-reader работает как простой пример.
2. Синхронизация описана протоколом и частично реализована как transport-wrapper. Production-реализация должна добавить E2E-шифрование, peer discovery, chunked file transfer, возобновление загрузок и UX выбора книг для нового устройства.
3. Relay не является облачным хранилищем: он не хранит книги, прогресс или закладки, но его надо запускать на своем сервере/VPS/NAS, если нужно соединять устройства вне одной LAN.

## Production-направление

Рекомендуемое ядро: Flutter UI + Rust native core через FFI для P2P/crypto/chunking + SQLite для локального состояния + MuPDF/Readium/форматные адаптеры для рендеринга.

## Сборка DMG/PKG/APK

Добавлены скрипты и GitHub Actions workflow для сборки установочных файлов без ручной установки Flutter на локальную машину:

- `scripts/package_macos.sh` — собирает `.app`, `.dmg`, `.pkg` на macOS;
- `scripts/package_android.sh` — собирает debug `.apk` для Android;
- `.github/workflows/build_installers.yml` — собирает артефакты на GitHub Actions;
- подробная инструкция: `docs/build_installers_ru.md`.

Для публичной раздачи macOS-сборок потребуется Apple Developer ID signing + notarization. Для Android production-сборки потребуется release signing keystore.

## Sprint 2: metadata sync через интернет

В обновлении Sprint 2 добавлена первая рабочая синхронизация metadata через self-hosted WebSocket relay:

- экран **Синхронизация** в приложении;
- настройка `Relay URL`;
- ручной MVP-pairing через одинаковый `accountId` на двух устройствах;
- отправка `library_snapshot` при подключении, добавлении книги, изменении прогресса и добавлении закладки;
- merge библиотеки, прогресса и закладок;
- отображение статуса книги: скачана локально или доступна на другом устройстве;
- Android INTERNET permission добавляется скриптом `prepare_flutter_platforms.sh`.

Подробности и сценарий проверки Mac ↔ Android: `docs/sprint_02_metadata_sync_ru.md`.

Важно: ручной `accountId` — временный тестовый pairing. Для production нужен QR-pairing, ключи устройств, подпись событий и E2E encryption.

## Sprint 3: скачивание файлов книг между устройствами

Добавлена MVP-передача оригинального файла книги через relay. Если книга видна в библиотеке, но не скачана на текущем устройстве, нажмите иконку облака в карточке книги. Устройство отправит `book_file_requested`, источник ответит `book_file_offer`, затем после `book_file_accept` отправит файл chunks. После получения файл проверяется по SHA-256 и только затем помечается как скачанный.

Подробности: `docs/sprint_03_file_transfer_ru.md`.

## Hotfix Sprint 3.1

Добавлено исправление для metadata-sync после Sprint 3: приложение теперь явно запрашивает `library_snapshot_requested` при подключении и на `peer_joined`, а экран синхронизации получил кнопку **Запросить snapshot у других устройств**.

TXT-reader больше не рендерит весь файл одним большим `SelectableText`; текст читается как bytes, поддерживает fallback Windows-1251 и отображается чанками через `ListView.builder`.

Подробнее: `docs/sprint_03_hotfix_01_ru.md`.

## Sprint 3 Hotfix 02

Если после Sprint 3 оба устройства подключены к relay, но библиотека не появляется на втором устройстве, обновите и перезапустите relay. Начиная с Hotfix 02 relay держит последние metadata snapshots в памяти процесса и отдаёт их новым подключившимся устройствам. Книги и file chunks не сохраняются.

Документация: `docs/sprint_03_hotfix_02_ru.md`.

## CI-тесты перед сборкой

Начиная с Sprint 3 cleanup 01, GitHub Actions сначала запускает обязательный job `Flutter and relay tests`.

Он выполняет:

```bash
./scripts/run_tests.sh
```

Внутри проверяются Flutter-тесты клиента и синтаксис relay-сервера. Android APK и macOS DMG/PKG собираются только если этот job завершился успешно.

## Sprint 4.0: публичный/self-hosted relay без ручного IP в будущем

Добавлена подготовка к zero-config sync endpoint:

- режим **ReadAnywhere relay** — endpoint компилируется в приложение через `READANYWHERE_DEFAULT_RELAY_URL`;
- режим **Свой relay** — для Koyeb/VPS/Cloudflare Tunnel/self-hosted;
- режим **Локальная разработка** — `http://127.0.0.1:8787`;
- после успешного подключения включается автоподключение при следующем запуске;
- relay теперь можно запускать через Docker/Docker Compose.

Документы:

```text
docs/relay_hosting_koyeb_ru.md
docs/sprint_04_0_hosted_relay_bootstrap_ru.md
```

Локальный Docker-запуск relay:

```bash
docker compose up --build relay
```

Сборка клиента с endpoint по умолчанию:

```bash
READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh
```

В GitHub Actions можно передать `default_relay_url` при ручном запуске workflow или создать repository variable `READANYWHERE_DEFAULT_RELAY_URL`.

## Sprint 4.0 hotfix 01 — macOS CI packaging

Исправлена ошибка macOS GitHub Actions build:

```text
DART_DEFINES[@]: unbound variable
```

Причина была в несовместимости пустого bash-массива с `set -u` на macOS bash 3.2. Скрипты `package_macos.sh` и `package_android.sh` теперь передают `--dart-define` без пустых массивов. Также исправлено добавление `CFBundleDisplayName` в macOS `Info.plist`.

## Sprint 4.1: Personal Hub + Tailscale Funnel

После проблем с бесплатными VPS/PaaS добавлен режим **Personal Hub / Tailscale Funnel**. Теперь relay можно запустить на своём Mac/PC/Linux-устройстве и опубликовать его в интернет через Funnel/Tunnel без белого IP, проброса портов и отдельного VPS.

Новые файлы:

```text
scripts/run_local_relay.sh
scripts/check_relay_health.sh
scripts/tailscale_start_funnel.sh
scripts/tailscale_status.sh
scripts/install_local_relay_service_macos.sh
scripts/uninstall_local_relay_service_macos.sh
scripts/install_local_relay_service_linux.sh
scripts/uninstall_local_relay_service_linux.sh
docs/relay_hosting_tailscale_funnel_ru.md
docs/relay_hosting_cloudflare_tunnel_ru.md
docs/sprint_04_1_personal_hub_tailscale_ru.md
docs/adr_004_transport_strategy_personal_hub.md
```

Быстрый запуск Personal Hub:

```bash
./scripts/run_local_relay.sh
```

Во втором терминале:

```bash
./scripts/tailscale_start_funnel.sh
```

В приложении:

```text
Синхронизация → Relay endpoint → Personal Hub / Tailscale Funnel
```

Вставьте HTTPS URL, который покажет Tailscale, нажмите **Проверить relay**, затем **Подключиться**.

Подробная инструкция: `docs/relay_hosting_tailscale_funnel_ru.md`.

## Sprint 4.1 cleanup: release-сборки меньшего размера

CI теперь публикует release-артефакты вместо debug-сборок:

```text
ReadAnywhere-android-release
  arm64-v8a release APK
  armeabi-v7a release APK
  x86_64 release APK
  Android App Bundle .aab
  SHA256SUMS

ReadAnywhere-macos-release-dmg-pkg
  release DMG
  release PKG
  release .app.zip
  SHA256SUMS
```

Debug-артефакты можно включить вручную при запуске workflow через параметр:

```text
build_debug_artifacts = true
```

Подробнее: `docs/sprint_04_1_cleanup_01_release_artifacts_ru.md`.


### Personal Hub connectivity hotfix

Если локальный relay запущен, но приложение показывает `Connection refused` на адресе `192.168.x.x:8787`, обновите скрипты из Sprint 4.1 Hotfix 01. Теперь `./scripts/run_local_relay.sh` по умолчанию слушает `0.0.0.0`, а не только `127.0.0.1`, и выводит LAN URL для проверки. Подробнее: `docs/sprint_04_1_hotfix_01_personal_hub_connectivity_ru.md`.


## Sprint 4.2: подключение по коду

Добавлен MVP-pairing: первое устройство создаёт 6-значный код подключения, новое устройство вводит код или вставляет `readanywhere://pair?...` приглашение и автоматически получает `accountId` и relay endpoint. Ручной ввод `accountId` оставлен только как fallback для разработки. Relay хранит pairing-коды только в памяти и удаляет их после первого использования или истечения срока. Подробности: `docs/sprint_04_2_pairing_codes_ru.md`.


## Sprint 4.2 cleanup: публикация GitHub Releases

CI теперь умеет автоматически публиковать установочные файлы в GitHub Releases. Для этого создайте и отправьте тег вида `v*`:

```bash
git tag v0.1.0-test
git push origin v0.1.0-test
```

Workflow соберёт Android/macOS release-артефакты, создаст или обновит GitHub Release и прикрепит APK/AAB/DMG/PKG/ZIP вместе с SHA256SUMS. Подробности: `docs/sprint_04_2_cleanup_01_github_releases_ru.md`.

## Hotfix: публикация GitHub Releases

Если workflow запускается по тегу `v*`, job `Publish GitHub Release` теперь явно делает checkout и передаёт `--repo`, поэтому публикация release работает и при создании тега через веб-интерфейс GitHub.

## Sprint 4.3: TXT locator fix

Исправлена проблема, когда процент чтения синхронизировался, но фактическое место открытия TXT на другом устройстве отличалось. TXT-reader теперь сохраняет content-based locator `txt-char-v1` с позицией в тексте (`charIndex`), а не пиксельный scroll offset. Подробнее: `docs/sprint_04_3_text_locator_ru.md`.

## Скачивание последних сборок

После каждого push в `main` workflow обновляет GitHub prerelease `main-latest`. Для обычного тестирования скачивайте APK/DMG/PKG из:

```text
Repository → Releases → main-latest
```

Для контрольной версии можно создать тег `v0.1.x-test`; workflow соберёт и опубликует отдельный versioned release без повторной ручной сборки.


## Sprint 5

Добавлено устойчивое скачивание книг: cancel/retry/resume partial chunks. Также исправлено восстановление места чтения TXT: reader перечитывает свежий locator из manifest и больше не должен открывать книгу с начала после закрытия.

Подробности: `docs/sprint_05_resumable_downloads_and_reader_restore_ru.md`.
