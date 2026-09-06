# Sprint 47A — Sync state и relay reliability

Исходный Sprint 47 разделён на два самостоятельных этапа. Этот документ
фиксирует Sprint 47A: версионирование протокола, конфликтную модель metadata,
idempotency, tombstones, авторизацию, durable relay и базовый restart/resume
механизм передачи. Расширенные fault-injection и file-transfer E2E проверки
реализованы следующим отдельным этапом и описаны в `sprint_47b_file_transfer_reliability_ru.md`.

## Проблемы до спринта

- metadata, прогресс и tombstones конкурировали через общий `updatedAt`;
- часы устройства участвовали в выборе победителя и отклонении событий;
- повторно доставленный snapshot заново проходил merge;
- bookmark tombstone удалялся из состояния сразу после merge;
- незавершённая передача жила главным образом в памяти `SyncService`;
- relay целиком перезаписывал общий `offline_queue.json` при каждом append/ACK.

## Sync protocol v3

Каждый envelope содержит явные `protocolVersion` и уникальный `operationId`. Эти поля дублируются внутри зашифрованного payload и проверяются после E2E-decrypt. Клиент поддерживает диапазон v2–v3 для контролируемого rollout; другие версии получают `unsupported_protocol_version` с поддерживаемым диапазоном.

`operationId` успешно применённых metadata-операций сохраняются в manifest (ограниченное окно 4096 идентификаторов). Повтор после reconnect или restart становится no-op. Relay также имеет уникальный SQLite-index `(account_id, operation_id)`.

## Логические ревизии и merge

Manifest schema v3 добавляет Lamport clock. Ревизия — пара `counter@deviceId`: сначала сравнивается counter, затем deviceId как детерминированный tie-break для одновременных offline-операций.

У книги независимы:

- `metadataRevision` — название, файл, availability и book tombstone;
- `progressRevision` — процент и locator;
- `BookmarkRecord.revision` — отдельная ревизия каждой закладки.

Поэтому переименование на A не стирает прогресс с B, а закладки обоих устройств объединяются. `updatedAt` остаётся диагностическим и v2-compatibility полем, но не определяет порядок v3. Расхождение системных часов не отклоняет корректно аутентифицированное событие.

Book и bookmark tombstones не фильтруются. Они несут `tombstoneAckedByDeviceIds`, при merge подтверждаются принимающим устройством и сохраняются как минимум до подтверждения всеми активными доверенными устройствами. В Sprint 47 автоматическая очистка tombstones намеренно не выполняется: более длительное хранение безопаснее преждевременного удаления. Реимпорт создаёт более высокую metadata revision; старый active snapshot удалить tombstone не может.

## Передача файлов

`FileTransferManager` сохраняет descriptor в `incoming/<bookId>.transfer.json` и данные в `<bookId>.part`. После restart новый `SyncService` читает journal, выравнивает partial по границе chunk и повторяет request с `startChunkIndex`. Перед публикацией файла выполняется SHA-256 всего полученного содержимого; mismatch удаляет повреждённый partial и не меняет manifest.

Binary frame v3 также содержит защищённые `protocolVersion` и детерминированный operation id chunk-а. Revoked/permission-disabled устройства отклоняются отдельно для metadata и file transfer. При появлении revocation очищаются выданные Direct/LAN tokens.

## Декомпозиция

`SyncService` остаётся фасадом для UI, но ответственность вынесена в отдельные используемые компоненты:

- `ConnectionManager` — endpoint, health probe, создание RelayClient и retry policy;
- `MetadataSyncEngine` — protocol compatibility, merge и durable idempotency;
- `PairingService` — HTTP transport pairing;
- `FileTransferManager` — restart journal, resume boundary и SHA-256;
- `DirectTransferServer` — временные LAN shares и HTTP Range.

## Relay

Общая JSON-перезапись заменена `offline_queue.sqlite3`: WAL + `synchronous=FULL`, транзакционный per-account sequence, unique operation id, durable ACK cursors и bounded TTL/size pruning. Relay по-прежнему хранит только непрозрачные E2E envelopes и не получает ключи, расшифрованную библиотеку или файлы книг.

## Поведенческие проверки

- два настоящих клиента `SyncService` + реальный uvicorn relay: progress A появляется на B;
- одновременные offline metadata/progress/bookmarks не теряются;
- повтор `operationId` до и после restart — no-op;
- старый snapshot не воскрешает удалённую книгу или закладку;
- clock skew 2000/2099 не меняет победителя Lamport revision;
- transfer journal восстанавливается после restart с aligned resume;
- полный файл принимается только при совпадении SHA-256;
- revoked и permission-disabled devices не имеют metadata/file capability;
- relay отвергает несовместимую версию контролируемой ошибкой;
- 50 конкурентных relay append сохраняются без потерь, cursor переживает restart.

## Передача в Sprint 47B

В следующем этапе выполняются расширенные end-to-end проверки передачи файлов:
принудительный обрыв relay и процесса клиента посередине нескольких chunks,
возобновление после restart через relay и Direct/LAN, повторы и перестановка
chunks, отзыв устройства во время активной передачи и итоговая матрица всех
девяти сценариев исходного Sprint 47. Правила protocol v3 при этом не меняются.
