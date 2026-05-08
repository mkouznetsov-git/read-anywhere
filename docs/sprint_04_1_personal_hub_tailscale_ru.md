# Sprint 4.1 — Personal Hub + Tailscale Funnel

## Цель

Уйти от обязательного VPS/Oracle/Koyeb и дать рабочую схему relay через одно из устройств пользователя.

## Что добавлено

- Режим endpoint: `Personal Hub / Tailscale Funnel`.
- Отдельное поле `Personal Hub URL`.
- Кнопка `Проверить relay` в UI.
- Скрипт локального запуска relay:

```bash
./scripts/run_local_relay.sh
```

- Скрипт проверки `/health`:

```bash
./scripts/check_relay_health.sh https://your-device.your-tailnet.ts.net
```

- Скрипт старта Tailscale Funnel:

```bash
./scripts/tailscale_start_funnel.sh
```

- macOS LaunchAgent для автозапуска локального relay.
- Linux systemd user service для автозапуска локального relay.
- Документация Tailscale Funnel и Cloudflare Tunnel fallback.

## Пользовательский сценарий

```text
1. На Mac/PC запускаем локальный relay.
2. Публикуем его через Tailscale Funnel.
3. Получаем HTTPS URL *.ts.net.
4. В ReadArc выбираем Personal Hub.
5. На других устройствах вставляем тот же URL и accountId.
6. Библиотека, прогресс и скачивание книг работают через хаб.
```

## Что это даёт

- Не нужен бесплатный VPS.
- Не нужен белый IP.
- Не нужен проброс портов.
- Не нужна платёжная карта для Oracle/Koyeb.
- Сохраняется философия: книги не хранятся в стороннем облаке.

## Ограничения

- Хаб-устройство должно быть включено.
- Если хаб спит, relay недоступен.
- Это ещё не production zero-config: accountId пока вводится вручную.
- Следующий шаг — pairing-код, который будет переносить и accountId, и endpoint автоматически.

## Проверки

1. `curl http://127.0.0.1:8787/health` работает на hub-устройстве.
2. `curl https://*.ts.net/health` работает с другого устройства.
3. Mac app подключается к Personal Hub URL.
4. Android app подключается к тому же Personal Hub URL.
5. Библиотека синхронизируется.
6. Книга скачивается с hub-устройства на Android.
7. Прогресс чтения синхронизируется обратно.
