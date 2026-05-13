# ReadArc relay deployment

Production relay работает на `https://relay.readarc.ru` за nginx/Let's Encrypt. Приложение всегда использует официальный relay, без выбора Personal Hub/Tailscale в пользовательском интерфейсе.

## Обновление через GitHub Actions

1. Убедитесь, что в `Settings → Secrets and variables → Actions → Repository secrets` есть:
   - `RELAY_HOST=relay.readarc.ru`
   - `RELAY_USER=root`
   - `RELAY_SSH_KEY=<private deploy key>`
2. Откройте `Actions → Deploy relay`.
3. Нажмите `Run workflow`.
4. После завершения проверьте:

```bash
curl https://relay.readarc.ru/health
```

## Локальное обновление ZIP-архивом

На сервере должен быть установлен `/usr/local/bin/readarc-update-relay`.

С Mac:

```bash
scripts/deploy_relay_zip.sh readarc_sprintXX.zip
```

Скрипт загрузит архив на сервер и выполнит:

```bash
readarc-update-relay /tmp/readarc-update.zip
```

## Что проверять после deploy

```bash
curl http://127.0.0.1:8787/health
curl https://relay.readarc.ru/health
```

Для Sprint 27+ в `/health` должны отображаться поля offline queue: `offline_queue_events` и `offline_queue_next_seq`.
