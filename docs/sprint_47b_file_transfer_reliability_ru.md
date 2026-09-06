# Sprint 47B — File transfer reliability

Sprint 47B завершает исходный Sprint 47 отдельным PR. Область изменений
ограничена передачей файлов и её fault-injection проверками; protocol v3,
Lamport merge и формат manifest из Sprint 47A не меняются.

## Restart/resume через relay

При любом `disconnect` активные download-сессии переводятся в paused state,
watchdog отменяется, а in-memory index очищается. Descriptor
`incoming/<bookId>.transfer.json` и уже подтверждённый `<bookId>.part` остаются
на диске. После нового подключения `SyncService` загружает journal, выравнивает
partial по безопасной границе chunk, создаёт новый transfer id и запрашивает
источник с `startChunkIndex`.

В integration-тесте два настоящих `SyncService` подключаются к отдельному
процессу uvicorn relay. Fault injector обрывает клиент после того, как первый
chunk сброшен на диск, но до ACK. Экземпляр клиента уничтожается, создаётся
заново с тем же storage, затем передача продолжается со следующей безопасной
границы. В manifest книга появляется только после проверки SHA-256 целого файла.

## Повторы и перестановка chunks

`FileTransferManager.commitChunk` является единственной точкой добавления
полученного chunk в partial:

- ожидаемый chunk записывается с `flush: true` до отправки ACK;
- повтор уже записанного chunk повторно подтверждается без изменения файла;
- преждевременный chunk отбрасывается без создания дырки и без завершения
  download-сессии — отправитель повторит отсутствующий chunk по ACK timeout;
- размер partial, индекс, chunk size и заявленный полный размер проверяются до
  записи.

Одинаковые правила используются binary relay и совместимым text fallback.

## Direct/LAN

Direct server поддерживает проверяемые single-range ответы `bytes=start-end`,
включая `Content-Range`, и отдаёт SHA-256 в заголовке. Клиент проверяет SHA и
точную начальную позицию range до append. Если Direct stream оборвался на
произвольном байте и требуется relay fallback, partial сначала снова
выравнивается через `FileTransferManager`; данные разных transport не могут быть
склеены со смещением.

Поведенческий тест загружает начало файла по Range, пересоздаёт
`FileTransferManager`, догружает остаток с сохранённой позиции и проверяет байты
и SHA-256. Отдельный тест отзывает share во время медленной активной HTTP
передачи: сервер закрывает уже открытый response, очищает token и возвращает 404
на повторный запрос.

## Отзыв устройства во время передачи

Источник перечитывает актуальный manifest перед каждым relay chunk и повторно
проверяет capability `fileTransfer`. Отзыв или запрет permission останавливает
upload до следующего chunk. Это проверяется двухклиентным тестом с реальным
relay. Direct/LAN revocation одновременно закрывает активные responses, а не
только запрещает создание следующего соединения.

## Итоговая матрица Sprint 47

| № | Обязательный сценарий | Поведенческая защита |
|---:|---|---|
| 1 | Progress A появляется на B через настоящий relay | `two clients exchange progress through a real relay process` |
| 2 | Одновременные offline-изменения A/B не теряются | `independent offline metadata, progress and bookmark revisions all survive` |
| 3 | Повтор операции идемпотентен, включая restart | `operationId remains idempotent after repository restart` и unique relay operation index |
| 4 | Старый snapshot не воскрешает книгу/закладку | book и bookmark tombstone tests в `sync_reliability_test.dart` |
| 5 | Файл переживает обрыв и restart | `relay file transfer resumes after client crash and verifies SHA-256`; Direct/LAN Range restart test |
| 6 | Полученный файл проходит SHA-256 | relay E2E, Direct/LAN E2E и corruption test `FileTransferManager` |
| 7 | Отозванное устройство не меняет metadata и не передаёт файлы | capability test, active relay revocation E2E и active Direct response revocation |
| 8 | Расхождение системного времени не ломает merge | `clock skew cannot resurrect a book deleted by a higher logical revision` |
| 9 | Старая версия протокола получает fallback/error | v2 fallback test и real relay `unsupported_protocol_version` test |

Все Dart-тесты запускаются общим `scripts/quality_gate.sh`; затем тот же verified
pipeline блокирует Android/macOS/iOS smoke, packages и release при любом падении.
