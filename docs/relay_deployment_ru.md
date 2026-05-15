# ReadArc relay deployment

Production relay работает на `https://relay.readarc.ru` за nginx/Let's Encrypt. Приложение использует официальный relay без выбора альтернативных transport-режимов в пользовательском интерфейсе.

## Обновление через GitHub Actions

1. Убедиться, что в `Settings → Secrets and variables → Actions → Repository secrets` есть:
   - `RELAY_HOST=relay.readarc.ru`
   - `RELAY_USER=root`
   - `RELAY_SSH_KEY=<private deploy key>`
2. Открыть `Actions → Deploy relay`.
3. Нажать `Run workflow`.
4. После завершения проверить:

```bash
curl https://relay.readarc.ru/health
```

Ожидаемый ответ:

```text
ok
```

## Что изменилось в update-команде

Workflow больше не полагается на заранее установленную старую версию `/usr/local/bin/readarc-update-relay`. Перед deploy он загружает свежий `scripts/readarc_update_relay.sh`, устанавливает его как `/usr/local/bin/readarc-update-relay` и только после этого запускает обновление.

Обновляющий скрипт:

- использует стабильный compose project name `readarc`;
- перед стартом новой версии выполняет `docker compose down --remove-orphans`;
- принудительно удаляет застрявшие контейнеры `readarc-relay-1` / `readarc_relay_1`;
- принудительно удаляет застрявшую сеть `readarc_default`;
- хранит relay-data вне папки приложения: `/opt/readarc/server_data/relay`;
- выполняет локальный health-check `http://127.0.0.1:8787/health`;
- при неуспехе откатывает папку приложения на предыдущий backup.

## Локальное обновление ZIP-архивом

С Mac:

```bash
scripts/deploy_relay_zip.sh readarc_sprintXX.zip
```

Локальный скрипт тоже загружает свежий updater и устанавливает его на сервер, поэтому отдельная ручная установка `/usr/local/bin/readarc-update-relay` больше не нужна.

## Что проверять после deploy

```bash
curl http://127.0.0.1:8787/health
curl https://relay.readarc.ru/health
```

В обоих случаях ожидается короткий ответ `ok` без диагностического JSON.
