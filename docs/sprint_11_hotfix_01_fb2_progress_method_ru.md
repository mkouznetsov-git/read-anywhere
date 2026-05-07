# Sprint 11 Hotfix 01 — исправление compile error FB2 reader

## Проблема

GitHub Actions падал на `compile_smoke_test.dart`:

```text
lib/main.dart:972:21: Error: The method '_progressForBlock' isn't defined for the type '_Fb2ReaderScreenState'.
```

В Sprint 11 FB2-reader вызывал helper `_progressForBlock(...)`, но метод не был добавлен в state-класс.

## Исправление

В `_Fb2ReaderScreenState` добавлен helper:

```dart
double _progressForBlock(int blockIndex, int blockCount) => _Fb2Locator(
  blockIndex: blockIndex.clamp(0, blockCount <= 0 ? 0 : blockCount - 1).toInt(),
  blockCount: blockCount,
).progressPercent;
```

Формат FB2 locator и протокол синхронизации не менялись.

## Проверка

После push должен пройти `compile_smoke_test.dart`, затем Android/macOS release-сборки.
