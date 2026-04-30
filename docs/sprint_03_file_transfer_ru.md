# Sprint 3 — скачивание оригинального файла книги между устройствами

## Цель

Если книга добавлена на одном устройстве, другое устройство уже видит её в общей библиотеке благодаря Sprint 2. В Sprint 3 добавлен следующий шаг: remote-only книгу можно скачать на текущее устройство через интернет.

Relay по-прежнему не хранит книги на диске. В MVP файл передаётся через WebSocket relay кусками в JSON/base64. Это проще для проверки end-to-end сценария, но production-версия должна перейти на binary frames, resume и P2P/relay fallback.

## Пользовательский сценарий

1. Mac и Android подключены к одному relay и используют один `accountId`.
2. Пользователь добавляет книгу на Mac.
3. Android видит книгу как `Не скачана здесь`.
4. Пользователь нажимает иконку скачивания на Android.
5. Android отправляет запрос файла.
6. Mac предлагает файл и после подтверждения отправляет chunks.
7. Android собирает временный файл, считает SHA-256 и сравнивает его с `contentSha256` из manifest.
8. Если SHA-256 совпал, файл перемещается в локальную папку `books`, а книга становится `Скачана на этом устройстве`.

## Протокол событий MVP

### `book_file_requested`

Отправляет устройство, на котором книга пока remote-only.

```json
{
  "type": "book_file_requested",
  "payload": {
    "transferId": "transfer-...",
    "bookId": "sha256...",
    "requestingDeviceId": "device-android",
    "fileName": "book.txt",
    "expectedSha256": "sha256...",
    "expectedSizeBytes": 12345,
    "preferredChunkSize": 262144
  }
}
```

### `book_file_offer`

Отправляет устройство-источник, если у него есть локальный файл.

```json
{
  "type": "book_file_offer",
  "payload": {
    "transferId": "transfer-...",
    "bookId": "sha256...",
    "sourceDeviceId": "device-mac",
    "requestingDeviceId": "device-android",
    "fileName": "book.txt",
    "format": "txt",
    "sizeBytes": 12345,
    "sha256": "sha256...",
    "chunkSize": 262144
  }
}
```

### `book_file_accept`

Отправляет скачивающее устройство. Это защищает MVP от ситуации, когда файл есть на нескольких устройствах: скачивающее устройство принимает первый подходящий offer и игнорирует остальные.

### `book_file_chunk`

Отправляет источник после `book_file_accept`.

```json
{
  "type": "book_file_chunk",
  "payload": {
    "transferId": "transfer-...",
    "bookId": "sha256...",
    "sourceDeviceId": "device-mac",
    "requestingDeviceId": "device-android",
    "chunkIndex": 0,
    "totalChunks": 10,
    "offset": 0,
    "totalBytes": 12345,
    "sha256": "sha256...",
    "dataBase64": "..."
  }
}
```

### `book_file_error`

Отправляется источником, если локальный файл исчез или произошла ошибка чтения.

## Проверки

### Mac → Android

1. Запустите relay.
2. Подключите Mac и Android к одному `accountId`.
3. Добавьте TXT-книгу на Mac.
4. Убедитесь, что Android видит книгу как remote-only.
5. Нажмите иконку скачивания на Android.
6. Дождитесь статуса `Скачано и проверено`.
7. Откройте книгу на Android.

### Проверка целостности

После получения всех chunks Android считает SHA-256 временного файла. Если hash не совпал, временный файл удаляется, а статус скачивания становится ошибочным. Книга не помечается как скачанная.

### Проверка обрыва связи

1. Начните скачивание крупного файла.
2. Остановите relay или отключите сеть.
3. Книга не должна стать `Скачана на этом устройстве`.
4. Повторный запуск скачивания создаст новый `transferId`.

## Ограничения Sprint 3

- Нет resume после обрыва передачи.
- Chunks идут последовательно, без parallel download.
- Передача идёт через JSON/base64, поэтому есть накладные расходы по размеру.
- Нет E2E encryption и подписи событий; это будет добавлено после QR-pairing/ключей.
- Relay не хранит offline queue: оба устройства должны быть online одновременно.

## Production-направление

Следующий шаг после Sprint 3:

1. QR-pairing и ключи устройств.
2. E2E encryption payload-событий.
3. Подпись событий и защита от replay.
4. Binary WebSocket frames вместо JSON/base64.
5. Resume chunk transfer.
6. LAN/P2P fast path, relay fallback через интернет.
