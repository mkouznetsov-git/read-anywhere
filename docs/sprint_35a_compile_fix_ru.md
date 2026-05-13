# Sprint 35a — compile fix для `_DjvuPageView`

## Что исправлено

В Sprint 35 постраничный DJVU reader передавал `key` в `_DjvuPageView`, но constructor виджета не принимал `super.key`.
Из-за этого GitHub Actions падал на compile smoke test с ошибкой:

```text
No named parameter with the name 'key'.
```

Исправление точечное:

```dart
class _DjvuPageView extends StatefulWidget {
  const _DjvuPageView({
    super.key,
    required this.sourceFile,
    required this.pagesDir,
    required this.pageNumber,
    required this.displayWidth,
    required this.displayHeight,
    required this.devicePixelRatio,
  });
}
```

## Версия

Flutter client обновлён до:

```text
0.1.0+37
```

## Relay

Relay обновлять не нужно. Серверный код не менялся.
