# Sprint 4.1 Hotfix 01 — Personal Hub connectivity

## Что исправлено

`run_local_relay.sh` раньше запускал relay на `127.0.0.1`. Это безопасно для Tailscale Funnel, но неудобно для LAN-проверки: адрес `http://192.168.x.x:8787` будет давать `Connection refused`, потому что сервер слушает только loopback-интерфейс.

Теперь `run_local_relay.sh` по умолчанию слушает `0.0.0.0`, то есть доступен с других устройств в локальной сети.

Для строго локального режима можно запустить так:

```bash
READARC_RELAY_HOST=127.0.0.1 ./scripts/run_local_relay.sh
```

## Как проверить локальный relay

На hub-компьютере:

```bash
./scripts/run_local_relay.sh
```

Скрипт выведет две проверки:

```text
Same computer: http://127.0.0.1:8787/health
LAN devices:   http://192.168.x.x:8787/health
```

Сначала проверьте на самом Mac:

```bash
curl http://127.0.0.1:8787/health
```

Потом проверьте LAN-адрес:

```bash
curl http://192.168.x.x:8787/health
```

Если LAN-адрес не работает, проверьте macOS Firewall:

```text
System Settings → Network → Firewall
```

И разрешите входящие подключения для Python/Terminal, если macOS спросит.

## Tailscale Funnel

`scripts/tailscale_start_funnel.sh` теперь лучше объясняет, что делать, если `tailscale` CLI не найден, и пробует найти Tailscale в стандартном `/Applications/Tailscale.app`.

Для macOS рекомендуется Standalone installer с сайта Tailscale, а не App Store-версия.

После установки Tailscale:

```bash
./scripts/run_local_relay.sh
```

Во втором терминале:

```bash
./scripts/tailscale_start_funnel.sh
```

В приложении используйте URL вида:

```text
https://your-device.your-tailnet.ts.net
```

## Короткая диагностика ошибки `Connection refused`

Если приложение показывает:

```text
SocketException: Connection refused, address = 192.168.x.x
```

значит по этому адресу и порту никто не слушает. Наиболее частые причины:

1. relay запущен на `127.0.0.1`, а приложение проверяет `192.168.x.x`;
2. relay не запущен;
3. macOS Firewall блокирует входящее подключение;
4. указан IP не того сетевого интерфейса.
