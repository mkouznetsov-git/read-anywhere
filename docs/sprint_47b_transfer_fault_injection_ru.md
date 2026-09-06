# Sprint 47B — fault-injection передачи файлов

Sprint 47B завершает reliability-часть Sprint 47. Он не меняет формат sync
protocol v3: вместо нового протокола добавлены реальные проверки аварийных
сценариев и исправлены найденные ими разрывы в lifecycle передачи.

## Исправленные дефекты

- При потере relay активная download-сессия больше не блокирует чтение durable
  journal после reconnect. Незавершённая relay-передача переводится в pause и
  автоматически создаёт новый idempotent request с продолжением от сохранённой
  границы chunk.
- `peer_left` прерывает upload и освобождает ACK waiter. После перезапуска
  процесса источника `peer_joined` заставляет получателя повторно запросить
  незавершённый файл без ручного нажатия.
- Принятый chunk записывается с `flush: true` до отправки ACK. Проверяются
  `bookId`, offset, общий размер, число chunks, размер текущего chunk и SHA-256
  descriptor. Несовместимый chunk не меняет `.part`.
- Повтор уже записанного chunk получает повторный ACK. Преждевременный chunk
  отбрасывается без удаления корректного partial и без сдвига позиции.
- Transfer journal теперь имеет verified temp/previous generations и
  восстанавливается, если процесс остановился между заменами файла журнала.
- Отзыв устройства или отключение его file-transfer permission немедленно
  прерывает активные upload/download и инвалидирует Direct/LAN tokens.
- Direct/LAN сервер проверяет token между порциями ответа. Отзыв доступа
  обрывает уже открытый stream; следующий запрос получает `404`.
- `SyncService.dispose()` дожидается уже начатых incoming/upload handlers, чтобы
  они не обращались к закрытому локальному хранилищу.

## Итоговая матрица из девяти сценариев

| № | Сценарий | Автоматическая проверка | Ожидаемый результат |
|---:|---|---|---|
| 1 | Несколько encrypted binary chunks через настоящий uvicorn relay | `real relay transfers multiple encrypted chunks...` | Файл публикуется только после полного SHA-256 |
| 2 | Повтор уже доставленного chunk | `duplicate, premature and tampered frames...` + `durable append accepts...` | Повтор не дописывается, ACK отправляется снова |
| 3 | Chunk приходит раньше ожидаемого | те же тесты | Partial не меняется, затем корректная последовательность завершается |
| 4 | Ciphertext/metadata chunk повреждены | fault integration + `incompatible offset, geometry, size or SHA...` | Повреждение отклоняется; manifest и partial не подменяются |
| 5 | Процесс получателя остановлен после нескольких chunks | `receiver process restart resumes...` | Новый `SyncService` читает journal и продолжает с durable boundary |
| 6 | Процесс источника остановлен после нескольких chunks | `source process restart makes the receiver re-request...` | `peer_left/peer_joined` запускают автоматический re-request/resume |
| 7 | Relay убит и поднят на том же порту в середине файла | `relay process restart resumes...` | Клиенты reconnect, binary не хранится relay, файл продолжается из local partial |
| 8 | Direct/LAN stream оборван, затем запрошен HTTP Range | `Direct/LAN resumes an interrupted transfer...` | Ответ `206` начинается точно с сохранённого byte offset, итоговый SHA совпадает |
| 9 | Устройство отозвано во время relay/Direct передачи | `revoking the receiver aborts...` + `revocation stops an active Direct/LAN stream...` | Передача прекращается, partial не публикуется, Direct token недействителен |

Дополнительно настоящий relay проверяет, что duplicate/reordered binary frames
пересылаются без модификации, отключившийся receiver не отравляет room, а после
restart сохраняется только durable encrypted metadata — binary chunks на диске
relay не появляются.

## Граница безопасности

Relay остаётся транспортом непрозрачных payload и не получает ключ аккаунта.
Файлы книг и binary chunks не добавлены в SQLite/offline queue. Source of truth
по-прежнему находится на устройствах; до совпадения full-file SHA-256 книга на
получателе остаётся remote-only.
