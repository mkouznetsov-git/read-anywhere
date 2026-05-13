# Sprint 27 — offline queue encrypted metadata events

## Цель

Сделать синхронизацию metadata-событий устойчивой к сценарию, когда одно устройство временно выключено или не имеет связи с relay.

MVP-этап проекта завершён; этот спринт сделан как production-доработка инфраструктуры синхронизации: relay не должен знать содержимое пользовательской библиотеки, но должен уметь временно хранить уже зашифрованные metadata-события и отдать их устройству после возвращения онлайн.

## Что изменено

### Relay

- Версия relay поднята до `0.3.0`.
- Добавлена bounded offline queue для encrypted metadata envelopes.
- Relay сохраняет только события, у которых `payload.e2ee` является объектом.
- Plaintext metadata не сохраняется.
- Binary file chunks не сохраняются.
- Сейчас в очередь попадают `library_snapshot` события.
- Каждому queued-событию присваивается `relayQueueSeq`.
- Устройство подтверждает обработку через `offline_queue_ack`.
- Relay хранит cursor по паре `accountId + deviceId`.
- TTL очереди по умолчанию: 30 дней.
- Максимум на аккаунт: 1000 metadata-событий.

### Persistence

Relay теперь использует runtime-директорию:

```text
/data/offline_queue.json
```

В `docker-compose.yml` добавлен volume:

```yaml
volumes:
  - ./server_data/relay:/data
```

Файл очереди не должен попадать в git; в корневой `.gitignore` добавлен `server_data/`.

### Client

- `SyncEnvelope` теперь умеет принимать и сериализовать `relayQueueSeq`.
- После успешной обработки queued-события клиент отправляет `offline_queue_ack`.
- Окно replay-protection для encrypted metadata увеличено до 30 дней, чтобы offline-события, накопленные relay, не отбрасывались как слишком старые.
- Дубликаты всё равно отсекаются по `eventId` внутри активного окна.

## Что relay НЕ делает

- Не хранит книги.
- Не хранит binary chunks.
- Не расшифровывает metadata.
- Не знает содержимое библиотеки, прогресса, закладок или списка книг.
- Не является источником истины: источником остаются подписанные и зашифрованные события устройств.

## Нужно ли обновлять relay на сервере

Да. Sprint 27 меняет серверную часть relay и `docker-compose.yml`.

После распаковки архива на VPS нужно пересобрать и перезапустить relay:

```bash
cd /opt/readarc/app

docker compose down
docker compose up -d --build relay

docker compose ps
curl http://127.0.0.1:8787/health
curl https://relay.readarc.ru/health
```

В `/health` теперь должны появляться поля:

```json
{
  "offline_queue_events": 0,
  "offline_queue_next_seq": 0
}
```

## Локальные и CI-проверки

Если GitHub Actions зелёные, локально полный прогон необязателен. Для быстрой локальной проверки:

```bash
cd apps/flutter_client
flutter pub get
flutter test
```

Для полного контроля:

```bash
cd apps/flutter_client
flutter clean
flutter pub get
flutter analyze
flutter test
```

Проверка relay-синтаксиса:

```bash
python3 -m py_compile server/rendezvous_relay/main.py
```

## Ручная проверка функционала

Сценарий Mac + Android:

1. Обновить relay на VPS.
2. Установить Sprint 27 на Mac и Android.
3. Убедиться, что оба устройства подключаются к `https://relay.readarc.ru`.
4. На Android полностью закрыть приложение или отключить интернет.
5. На Mac открыть книгу, изменить позицию чтения, добавить/удалить книгу или изменить доверенные устройства.
6. Подождать 10–20 секунд, чтобы Mac отправил `library_snapshot`.
7. Проверить на VPS:

```bash
curl https://relay.readarc.ru/health
```

Ожидаемо `offline_queue_events` должен стать больше нуля для аккаунта.

8. Включить Android / открыть приложение.
9. Android должен получить накопленные encrypted metadata-события и догнать состояние.
10. Повторно проверить `/health`: после ack от Android cursor должен продвинуться; очередь может остаться до TTL/лимита, но повторная доставка уже не должна происходить для подтверждённого устройства.

## Ограничения текущего спринта

- Очередь хранит metadata-события, не файлы.
- Если устройство офлайн, оно не сможет скачать книгу, пока не будет онлайн устройство-источник с файлом. Это будет закрываться отдельной задачей UX: “Включите устройство, где хранится книга”.
- Подпись событий пока остаётся transition-механизмом HMAC account-key; следующий security-шаг — настоящая Ed25519-подпись устройством и проверка по trusted public key.
