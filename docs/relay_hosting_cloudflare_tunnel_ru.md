# Альтернатива: ReadAnywhere relay через Cloudflare Tunnel

Этот путь оставлен как запасной вариант. Он полезен, если Tailscale Funnel не подошёл.

Схема:

```text
ReadAnywhere app
  ↓ https/wss
Cloudflare Tunnel URL
  ↓
cloudflared на вашем устройстве
  ↓ localhost:8787
ReadAnywhere FastAPI relay
```

## Quick Tunnel для разработки

1. Запустите локальный relay:

```bash
./scripts/run_local_relay.sh
```

2. В другом терминале установите и запустите `cloudflared`:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
```

3. Cloudflare выдаст временный URL вида:

```text
https://something.trycloudflare.com
```

4. В ReadAnywhere выберите:

```text
Синхронизация → Relay endpoint → Personal Hub / Tailscale Funnel
```

и вставьте этот URL.

## Ограничения

- Quick Tunnel URL временный и меняется после перезапуска.
- Для постоянного Cloudflare Tunnel обычно нужен домен в Cloudflare.
- Для нашего текущего MVP Tailscale Funnel предпочтительнее, потому что проще получить стабильный HTTPS URL без собственного домена.
