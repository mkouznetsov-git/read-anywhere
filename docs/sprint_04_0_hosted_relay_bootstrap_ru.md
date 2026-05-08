# Sprint 4.0 — Hosted relay bootstrap

Цель: подготовить проект к работе без ручного IP-адреса в обычном сценарии, но сохранить возможность self-hosted/custom relay.

## Реализовано

### 1. Режимы endpoint

В приложении появились режимы:

```text
ReadArc relay
Свой relay
Локальная разработка
```

Пока официальный relay задаётся на этапе сборки через:

```bash
--dart-define=READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app
```

Или через env-переменную в наших скриптах:

```bash
READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh
```

### 2. Custom relay остался

Пользователь или разработчик может указать свой endpoint:

```text
https://your-service.koyeb.app
http://192.168.1.10:8787
```

Клиент сам строит WebSocket route:

```text
/ws/{accountId}/{deviceId}
```

### 3. Автоподключение

После успешного подключения настройка сохраняется с `autoConnect=true`. При следующем запуске приложение пробует подключиться автоматически.

Кнопка **Отключиться** выключает `autoConnect`.

### 4. Docker-ready relay

Добавлены:

```text
server/rendezvous_relay/Dockerfile
server/rendezvous_relay/Procfile
docker-compose.yml
```

### 5. CI обновлён

GitHub Actions теперь позволяет передать `default_relay_url` при ручном запуске workflow. Скрипты сборки передают его во Flutter через `--dart-define`.

Также workflow переведён на более новые версии базовых actions:

```text
actions/checkout@v6
actions/setup-java@v5
actions/upload-artifact@v6
```

### 6. Relay smoke checks

`scripts/run_tests.sh` теперь дополнительно собирает Docker image relay, если на машине доступен Docker.

## Проверки

1. Локальный режим:

```bash
docker compose up --build relay
```

В приложении выбрать:

```text
Локальная разработка
```

2. Koyeb/custom режим:

```text
Синхронизация → Relay endpoint → Свой relay → https://your-service.koyeb.app
```

3. Build-time default:

```bash
READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh
```

В приложении выбрать:

```text
ReadArc relay
```

## Следующий спринт

Sprint 4.1 — pairing без ручного `accountId`:

```text
Добавить устройство
pairing-код
автоматическая передача accountId
список доверенных устройств
удаление устройства из аккаунта
```
