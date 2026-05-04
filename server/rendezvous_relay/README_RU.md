# ReadAnywhere Rendezvous Relay

Назначение: временно соединять устройства одного аккаунта, когда прямое LAN/P2P соединение недоступно.

Важно: relay не является облачным хранилищем.

- Данные хранятся только в памяти текущего процесса.
- Сообщения не пишутся на диск.
- История сообщений не сохраняется.
- Книги не сохраняются на сервере.
- Production-клиент должен шифровать payload end-to-end.

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
docker build -t readanywhere-relay .
docker run --rm -p 8787:8787 -e PORT=8787 readanywhere-relay
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
