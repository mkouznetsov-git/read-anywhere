# Тест-план Read anywhere

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
