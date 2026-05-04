# ReadAnywhere relay через Tailscale Funnel

Цель: получить публичный HTTPS endpoint для текущего Python/FastAPI relay без VPS, белого IP, проброса портов и платёжной карты.

Схема:

```text
ReadAnywhere app
  ↓ https/wss
Tailscale Funnel URL (*.ts.net)
  ↓
Ваш Mac / Windows / Linux
  ↓ localhost:8787
ReadAnywhere FastAPI relay
```

Важно: устройство, на котором работает relay, становится временным **Personal Hub**. Оно должно быть включено и подключено к интернету, пока другие устройства синхронизируются через него.

## 1. Установить Tailscale

Установите Tailscale на устройство-хаб:

- macOS / Windows / Linux: https://tailscale.com/download
- войдите в аккаунт Tailscale;
- убедитесь, что устройство видно в Tailscale admin console.

## 2. Запустить локальный ReadAnywhere relay

В корне проекта:

```bash
./scripts/run_local_relay.sh
```

По умолчанию relay слушает:

```text
http://127.0.0.1:8787
```

Проверка:

```bash
./scripts/check_relay_health.sh http://127.0.0.1:8787
```

Ожидаемый ответ содержит `"ok": true`.

## 3. Включить Funnel в Tailscale admin console

В зависимости от версии интерфейса Tailscale пункт может называться немного иначе.

Обычно путь такой:

```text
Tailscale admin console
→ Settings
→ Network / Services / Funnel
→ Enable Funnel
```

Если включение Funnel требует подтверждения политики tailnet, следуйте подсказкам Tailscale.

## 4. Опубликовать локальный relay через Funnel

Во втором терминале из корня проекта:

```bash
./scripts/tailscale_start_funnel.sh
```

Скрипт выполнит команду вида:

```bash
sudo tailscale funnel --https=443 8787
```

Tailscale должен показать публичный URL, например:

```text
https://your-mac.your-tailnet.ts.net
```

Скопируйте этот URL.

## 5. Проверить публичный URL

С другого устройства или с телефона через мобильный интернет откройте:

```text
https://your-mac.your-tailnet.ts.net/health
```

Или выполните:

```bash
./scripts/check_relay_health.sh https://your-mac.your-tailnet.ts.net
```

## 6. Подключить ReadAnywhere

В приложении:

```text
ReadAnywhere
→ Синхронизация
→ Relay endpoint
→ Personal Hub / Tailscale Funnel
→ Personal Hub URL
```

Вставьте:

```text
https://your-mac.your-tailnet.ts.net
```

Нажмите:

```text
Проверить relay
Подключиться
```

На втором устройстве укажите тот же `accountId`, затем тот же Personal Hub URL.

## 7. Автозапуск локального relay

### macOS

```bash
./scripts/install_local_relay_service_macos.sh
```

Удаление:

```bash
./scripts/uninstall_local_relay_service_macos.sh
```

### Linux

```bash
./scripts/install_local_relay_service_linux.sh
```

Удаление:

```bash
./scripts/uninstall_local_relay_service_linux.sh
```

## 8. Ограничения режима Personal Hub

- Хаб-устройство должно быть включено.
- Если хаб засыпает, синхронизация временно недоступна.
- Funnel — транспортный сервис Tailscale; книги всё равно не хранятся в облачном хранилище ReadAnywhere.
- Для production позже нужен либо официальный serverless relay, либо self-hosted relay, либо устойчивый Personal Hub/NAS.

## 9. Быстрая диагностика

Локальный relay:

```bash
curl http://127.0.0.1:8787/health
```

Tailscale:

```bash
./scripts/tailscale_status.sh
```

Публичный endpoint:

```bash
curl https://your-mac.your-tailnet.ts.net/health
```

Если `/health` работает, но приложение не синхронизируется, проверьте:

- одинаковый `accountId` на обоих устройствах;
- выбран режим `Personal Hub / Tailscale Funnel`;
- в URL нет `/health` на конце;
- оба устройства подключены к одному relay URL.
