# Архитектура Read anywhere

## Главный принцип

Read anywhere — local-first приложение. Каждое устройство хранит собственную копию метаданных аккаунта, прогресса, закладок и выбранных книг. Нет центральной базы с библиотекой и нет облачного хранения файлов книг.

## Компоненты

### 1. Client App

Один клиентский код для Android, iOS, macOS, Windows, Linux.

Функции:

- библиотека книг;
- импорт книги;
- отображение статуса `скачана / только в библиотеке`;
- чтение;
- сохранение прогресса и текущей позиции;
- закладки;
- список устройств аккаунта;
- выбор книг для скачивания на новое устройство;
- синхронизация metadata-first, file-on-demand.

### 2. Local Storage

Рекомендуется SQLite + файловое хранилище:

```text
ReadAnywhere/
  account.db
  books/
    <sha256>.<ext>
  covers/
    <sha256>.jpg
  cache/
```

MVP использует `manifest.json`, чтобы стартовый код был проще.

### 3. Sync Core

Синхронизируются два типа данных:

1. **Metadata** — список книг, прогресс, locator, закладки, список устройств, наличие файла на устройствах.
2. **Content** — сами файлы книг, передаются только если пользователь выбрал скачать книгу на устройство.

Metadata синхронизируется всегда. Content — только по запросу.

### 4. Transport

Уровни транспорта:

1. LAN discovery: mDNS/Bonjour + прямое соединение.
2. P2P через интернет: libp2p/WebRTC/QUIC с hole punching.
3. Optional rendezvous relay: самохостируемый signaling/relay без записи данных на диск.

Relay не должен хранить сообщения, книги или manifest. Весь payload должен быть E2E-зашифрован.

## Сущности

### Account

Локальная криптографическая идентичность пользователя. Аккаунт создается на первом устройстве, а новое устройство присоединяется через pairing QR-код/одноразовый код.

### Device

```json
{
  "deviceId": "uuid",
  "name": "MacBook Air",
  "publicKey": "base64",
  "lastSeenAt": "2026-04-29T10:30:00Z"
}
```

### Book

```json
{
  "id": "sha256-of-content",
  "title": "Book title",
  "format": "epub",
  "sizeBytes": 123456,
  "contentSha256": "...",
  "addedAt": "...",
  "updatedAt": "..."
}
```

### Reading State

```json
{
  "bookId": "...",
  "progressPercent": 42.7,
  "locator": "epubcfi(...) / page / scroll-offset",
  "updatedAt": "...",
  "updatedByDeviceId": "...",
  "version": 17
}
```

### Bookmark

```json
{
  "id": "uuid",
  "bookId": "...",
  "label": "Глава 3",
  "locator": "...",
  "note": "optional",
  "createdAt": "...",
  "updatedAt": "...",
  "deletedAt": null
}
```

## Merge rules

- Books: union by `contentSha256`.
- Reading state: Last-Writer-Wins by `(version, updatedAt, updatedByDeviceId)`. Для одного читателя это достаточно; для family mode позже лучше CRDT per profile.
- Bookmarks: OR-Set with tombstones: добавление/удаление не теряются при offline-merge.
- Device availability: per-device heartbeat + локальный индекс `bookId -> deviceIds`, где есть файл.

## Security

- Account recovery key: показывается пользователю при создании аккаунта.
- Pairing: QR-код содержит одноразовый invitation token и public key первого устройства.
- Каждое устройство имеет Ed25519 identity key и X25519 encryption key.
- Все sync envelopes подписываются и шифруются.
- Relay видит только account room/device id и размеры сообщений; payload зашифрован.

## Форматы книг

Рекомендуемые адаптеры:

- EPUB/PDF: Readium или MuPDF.
- FB2/MOBI/CBZ/XPS: MuPDF/PyMuPDF/нативные адаптеры.
- DOCX: распаковка OOXML + извлечение текста/HTML, либо конвертация в EPUB/PDF.
- DOC: через LibreOffice/headless converter на desktop или serverless local converter; на мобильных лучше попросить пользователя импортировать DOCX/PDF.
- DJVU: DjVuLibre/native bridge.

## UI

Минималистичный теплый стиль:

- фон: теплый светлый `#F8F1E7`;
- карточки: `#FFF9F0`;
- текст: мягкий темно-коричневый;
- акцент: приглушенная медь;
- минимум элементов на reader screen: текст, прогресс, кнопка закладки, настройки шрифта.

## Update after scope clarification: internet sync

The product must sync over the internet, not only inside LAN. The chosen approach is a self-hosted rendezvous/relay service that never stores account data or book files. Devices keep the authoritative local copies. The relay only helps devices discover each other and, when direct P2P is unavailable, forwards encrypted messages/chunks in transit.

See also: `docs/adr_002_internet_sync_and_format_scope.md`.
