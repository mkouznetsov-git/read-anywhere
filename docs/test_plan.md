# Тест-план ReadAnywhere

## Unit

- `BookRecord.fromJson/toJson` сохраняет все поля.
- Merge metadata идемпотентен.
- LWW progress не откатывается на старые данные.
- Bookmark tombstone побеждает старое добавление.
- SHA-256 одинаков для одинакового файла.

## Integration

- Import -> restart -> library persists.
- Device A changes progress -> Device B receives metadata -> progress updated.
- Device A adds bookmark offline, Device B adds another bookmark offline -> both bookmarks visible after sync.
- Device B downloads selected book from Device A -> hash verified.

## End-to-end

- Android -> Windows: add book, read 12%, continue on Windows.
- macOS -> iPhone: add bookmark, see bookmark on iPhone.
- Linux -> Android over LAN without relay.
- Windows -> iOS through self-hosted relay.

## Negative/security

- Unknown device cannot join account.
- Tampered envelope rejected.
- Tampered chunk rejected.
- Replay of old progress does not overwrite new progress.
- Relay restart does not lose stored data, because relay stores no data by design.

## Performance

- Library with 10 000 metadata records opens under target time.
- 1 GB PDF import does not block UI.
- Metadata sync under 1 MB for normal library.
- Chunk transfer throttling respects battery/network settings.

## Sprint 2 — проверка metadata sync через интернет

### Тест 2.1: один accountId на двух устройствах

1. Запустить relay на публично доступном адресе.
2. Открыть экран синхронизации на Mac.
3. Скопировать `accountId`.
4. Открыть экран синхронизации на Android.
5. Вставить тот же `accountId` и нажать **Сохранить**.
6. Подключить оба устройства к одному `Relay URL`.

Ожидаемый результат: оба устройства показывают статус `Подключено`.

### Тест 2.2: новая книга

1. Добавить TXT-книгу на Mac.
2. Дождаться отправки snapshot или нажать **Отправить snapshot библиотеки**.

Ожидаемый результат: Android показывает эту книгу как remote-only, без локального пути, со статусом доступности на другом устройстве.

### Тест 2.3: прогресс чтения

1. Открыть TXT-книгу на устройстве, где она скачана.
2. Прокрутить текст.
3. Дождаться auto-save progress.

Ожидаемый результат: второе устройство после получения snapshot показывает обновленный процент чтения.

### Тест 2.4: закладки

1. Добавить закладку на Mac.
2. Добавить другую закладку на Android для той же книги, если файл также импортирован на Android.
3. Отправить snapshot с обоих устройств.

Ожидаемый результат: обе закладки присутствуют на обоих устройствах.

### Тест 2.5: локальный путь не перезаписывается

1. Импортировать одну и ту же книгу на Mac и Android.
2. Синхронизировать snapshot.

Ожидаемый результат: каждый клиент сохраняет свой `localPath`, а `availableOnDeviceIds` содержит оба устройства.

## Sprint 3 — File transfer tests

1. Add a TXT book on macOS while Android is connected to the same account.
2. Verify Android shows the book as remote-only.
3. Tap the cloud download button on Android.
4. Verify transfer progress is shown in the book card.
5. Verify final status becomes `Скачано и проверено`.
6. Verify the book can be opened on Android and reading progress still syncs back to macOS.
7. Interrupt relay during a large transfer and verify the book is not marked as downloaded.
8. Retry download and verify SHA-256 validation succeeds.
