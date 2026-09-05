# Sprint 46 — Data durability

## Карта исходных путей

До Sprint 46 владельцем `manifest.json` формально был `StorageService`, но транзакционной границы не было:

- импорт: `BookImportService.importFile → loadManifest → copy file → upsertBook → load/modify/save`;
- прогресс и закладки: reader UI → `updateProgress` / `addBookmark → load/modify/save`;
- библиотека: rename, delete, local-copy removal и download completion → отдельные `load/modify/save`;
- pairing/trust: account replacement, device rotation, trust/revoke/prune/touch → отдельные `load/modify/save`;
- sync: `_handleLibrarySnapshot → mergeManifests → saveManifest`, конкурентно локальным операциям;
- startup: `loadManifest` мог сам мигрировать ключи и затем вызвать `saveManifest`.

Последняя завершившаяся запись могла стереть уже сохранённое изменение другой операции.

## Реализация

`LibraryRepository` стал единственной границей чтения и изменения metadata. `read`, `mutate` и `replace` проходят через одну последовательную очередь. Callback мутации всегда получает последнее сохранённое состояние. `StorageService` оставлен фасадом доменных операций, чтобы дальнейшая замена JSON на SQLite не меняла UI и sync API.

Формат получил `schemaVersion: 2` и последовательный migration pipeline. Миграция v1→v2 идемпотентно переносит `accountEncryptionKey` и `deviceSigningPrivateKey` в системное защищённое хранилище. В обычном JSON остаются только публичные идентификаторы и публичный signing key. На Android используется Keystore-backed secure storage, на macOS — Keychain.

Commit выполняется так:

1. сериализация в уникальный temp-файл;
2. flush;
3. повторное чтение, migration и структурная валидация temp;
4. создание и повторная проверка backup текущего поколения;
5. переименование текущего файла в `manifest.json.previous`;
6. атомарное переименование temp в `manifest.json`;
7. повторная проверка committed-файла и удаление previous.

При повреждении основной файл карантинируется вместе с причиной. Recovery проверяет `manifest.json.previous`, затем несколько backup от новых к старым. Если валидного поколения нет, выбрасывается диагностируемая `ManifestRecoveryException`; пустая библиотека не создаётся. Потенциально разрушительная замена непустой библиотеки также отклоняется с копией кандидата в `manifest_rejected`.

## Проверки

`library_repository_test.dart` использует временную файловую систему и проверяет:

- три конкурентные мутации;
- progress одновременно с import;
- remote snapshot одновременно с локальной мутацией;
- аварийно оставленный temp;
- повреждение main и восстановление из backup;
- повреждение main и последнего backup с fallback на более старое поколение;
- миграцию v1→v2 и повторный идемпотентный запуск;
- сохранность книг, прогресса, закладок и pairing после restart;
- ошибку записи без замены существующей библиотеки пустым состоянием.

## Граница Sprint 47

Sync-протокол и модель конфликтов намеренно не менялись. Sprint 47 может перенести merge в отдельный metadata engine, используя ту же `mutate`-границу. Переход metadata на SQLite должен быть отдельной обратимой миграцией с dual-read/verification планом.
