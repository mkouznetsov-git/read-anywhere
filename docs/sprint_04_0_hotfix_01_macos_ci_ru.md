# Sprint 4.0 hotfix 01 — исправление macOS CI package script

## Проблема

macOS job падал на шаге:

```bash
./scripts/package_macos.sh
```

с ошибкой:

```text
./scripts/package_macos.sh: line 20: DART_DEFINES[@]: unbound variable
```

Причина: на macOS GitHub runner используется системный bash 3.2. При `set -u` пустой bash-массив может вести себя иначе, чем на свежем bash в Ubuntu runner. Android job проходил, потому что там bash новее.

Отдельное сообщение:

```text
Set: Entry, ":CFBundleDisplayName", Does Not Exist
```

не было основной причиной падения, но тоже исправлено: теперь ключ добавляется, если его нет.

## Исправление

1. Убрано использование пустого массива `DART_DEFINES` в shell-скриптах.
2. `--dart-define` теперь передаётся условно:

```bash
if [[ -n "${READARC_DEFAULT_RELAY_URL:-}" ]]; then
  flutter build macos --release --dart-define="READARC_DEFAULT_RELAY_URL=${READARC_DEFAULT_RELAY_URL}"
else
  flutter build macos --release
fi
```

3. Такое же исправление внесено в Android packaging script для одинаковой переносимости.
4. `package_macos.sh` теперь явно генерирует только macOS platform folder, а не `android,macos`.
5. `prepare_flutter_platforms.sh` теперь добавляет `CFBundleDisplayName`, если ключ отсутствует.

## Проверка

В этой среде проверены:

```bash
bash -n scripts/package_macos.sh scripts/package_android.sh scripts/prepare_flutter_platforms.sh scripts/run_tests.sh
python3 -m py_compile server/rendezvous_relay/main.py
```

Flutter/macOS build должен пройти в GitHub Actions.
