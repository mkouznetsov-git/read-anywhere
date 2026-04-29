# Read Anywhere Rendezvous Relay

Назначение: временно соединять устройства одного аккаунта, когда прямое LAN/P2P соединение недоступно.

Важно: relay не является облачным хранилищем.

- Данные хранятся только в памяти текущего процесса.
- Сообщения не пишутся на диск.
- История сообщений не сохраняется.
- Production-клиент должен шифровать payload end-to-end.

## Запуск

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8787
```

## Endpoint

```text
ws://host:8787/ws/{account_id}/{device_id}
```

Все JSON-сообщения от одного устройства пересылаются другим устройствам в той же комнате `account_id`.
