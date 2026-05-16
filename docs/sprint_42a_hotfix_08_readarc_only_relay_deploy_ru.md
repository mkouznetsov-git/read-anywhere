# Sprint 42A Hotfix 08 — ReadArc-only cleanup и устойчивый relay deploy

## Цель

Убрать остатки старого имени проекта и исправить падение relay deploy из-за застрявших Docker container/network.

## ReadArc-only cleanup

- Удалены оставшиеся остатки прежнего имени проекта строки из кода, workflow, скриптов и документации.
- Убрана совместимость со старыми pairing links прежнего имени проекта.
- Убрана совместимость со старыми E2E payload версиями.
- Убрана миграция данных из папки прежнего имени проекта.
- Каноническая локальная папка данных разработки/тестирования: `ReadArc`.
- Каноническая переменная relay endpoint: `READARC_DEFAULT_RELAY_URL`.

## Relay deploy

Причина падения из лога: старая update-команда пыталась поднять новый compose-проект, когда старые Docker objects ещё существовали:

- container: `readarc-relay-1`;
- network: `readarc_default`.

Из-за этого Docker вернул conflict, а workflow завершился exit code 1 даже после успешного rollback.

Исправления:

- добавлен `scripts/readarc_update_relay.sh`;
- GitHub Actions теперь загружает свежий updater на сервер перед каждым deploy;
- updater делает `docker compose down --remove-orphans`;
- updater удаляет застрявшие `readarc-relay-1` / `readarc_relay_1`;
- updater удаляет застрявшую сеть `readarc_default`;
- relay data вынесены в стабильную директорию `/opt/readarc/server_data/relay`;
- `docker-compose.yml` использует `${READARC_RELAY_HOST_DATA_DIR:-./server_data/relay}`.

## Relay

Relay через SSH обновлять нужно, если нужен новый короткий `/health = ok` и исправленный update pipeline.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
```

Проверка отсутствия старого имени:

```bash
grep -RIn "<legacy-project-name-patterns>" .
```

Ожидаемо: ничего не найдено.

Проверка relay после deploy:

```bash
curl https://relay.readarc.ru/health
```

Ожидаемо:

```text
ok
```
