# Sprint 42A Hotfix 01 — CI script permissions

## Причина

GitHub Actions упал на шаге:

```text
./scripts/run_tests.sh: Permission denied
```

Причина не в DOCX engine и не в тестах приложения. При упаковке архива shell-скрипты потеряли executable bit.

## Исправление

В архиве восстановлен executable bit для всех shell-скриптов в `scripts/`:

```bash
chmod +x scripts/*.sh
```

Особенно важны:

- `scripts/run_tests.sh`
- `scripts/package_android.sh`
- `scripts/package_macos.sh`
- `scripts/prepare_flutter_platforms.sh`
- `scripts/build_native_engines.sh`

## Relay

Relay обновлять через SSH не нужно.

## Локальная проверка

```bash
ls -l scripts/*.sh
./scripts/run_tests.sh
```

У скриптов должны быть права вида `-rwxr-xr-x`.

## Git-проверка перед push

```bash
git ls-files -s scripts/run_tests.sh scripts/package_android.sh scripts/package_macos.sh
```

Для исполняемых скриптов режим должен быть `100755`, а не `100644`.

Если локальный git не зафиксировал смену режима, выполнить:

```bash
git update-index --chmod=+x scripts/*.sh
```
