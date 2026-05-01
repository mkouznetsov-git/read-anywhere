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
