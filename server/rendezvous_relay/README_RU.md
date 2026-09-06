# ReadArc Rendezvous Relay

Назначение: временно соединять устройства одного аккаунта, когда прямое LAN/P2P соединение недоступно.

Важно: relay не является облачным хранилищем книг или открытых metadata.

- Онлайн-комнаты и snapshot cache живут только в памяти процесса.
- Ограниченная offline-очередь E2E-envelopes хранится транзакционно в `/data/offline_queue.sqlite3` (SQLite WAL).
- Relay обеспечивает idempotency по `operationId` и durable ACK-cursor каждого устройства.
- Расшифрованные metadata и книги не сохраняются на сервере.
- Production-клиент шифрует payload end-to-end.

## Локальный запуск

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8787
```

Проверка:

```bash
curl http://127.0.0.1:8787/health
```

## Docker

Из корня репозитория:

```bash
docker compose up --build relay
```

Или напрямую:

```bash
cd server/rendezvous_relay
docker build -t readarc-relay .
docker run --rm -p 8787:8787 -e PORT=8787 readarc-relay
```

## Endpoint

Base URL для приложения:

```text
http://host:8787
https://your-app.koyeb.app
```

WebSocket route внутри relay:

```text
/ws/{account_id}/{device_id}
```

Клиент сам преобразует `https://...` в `wss://...`, а `http://...` в `ws://...`.

## Проверка с приложениями

1. Запустите relay на сервере, доступном обоим устройствам.
2. В приложении откройте **Синхронизация**.
3. Выберите **Свой relay**.
4. Укажите base URL, например `https://your-app.koyeb.app`.
5. На обоих устройствах используйте одинаковый `accountId` до появления нормального pairing.
6. Нажмите **Подключиться**.

Текущий relay всё ещё in-memory only: он не пишет книги, прогресс, закладки или историю сообщений на диск.

## Sprint 4.2: pairing endpoints

Relay версии 0.1.3 поддерживает временные pairing-коды:

```text
POST /pairing/start
POST /pairing/claim
```

Коды хранятся только в памяти процесса, живут до 5 минут и удаляются после первого использования. Они нужны только для передачи `accountId` и relay endpoint новому устройству без ручного копирования accountId.

## Sprint 27: durable encrypted metadata offline queue

Relay версии `0.3.0` поддерживает bounded offline queue для encrypted metadata events.

Настройки окружения:

```text
READARC_RELAY_DATA_DIR=/data
READARC_OFFLINE_QUEUE_TTL_SECONDS=2592000
```

В Docker Compose runtime-состояние монтируется в:

```text
./server_data/relay:/data
```

Relay сохраняет только encrypted envelope JSON с `payload.e2ee`; книги, бинарные chunks и plaintext metadata не сохраняются.
