# Sprint 28b — каноническая иконка ReadArc

## Что изменено

Обновлены все committed PNG-иконки ReadArc на канонический вариант:

- `assets/app_icon/readarc_icon_1024.png`
- `assets/app_icon/android/ic_launcher_*.png`
- `assets/app_icon/macos/app_icon_*.png`
- `apps/flutter_client/assets/brand/readarc_icon_1024.png`
- `apps/flutter_client/assets/brand/readarc_icon_128.png`

Сохранены утверждённые композиция и палитра ReadArc: глубокий индиго, тёплое золото, кремовая бумага, чернильно-синие буквы.

Буквы `R` и `A` подняты чуть выше и сильнее вписаны в перспективу страниц.

## Серверный relay

Обновлять relay на сервере не нужно: это только замена графических assets приложения.

## Проверка

После сборки проверить:

1. Android launcher icon.
2. macOS app icon в Finder/Dock.
3. Иконку ReadArc внутри приложения, если она отображается на экранах.

Если ОС показывает старую иконку, это может быть системный кэш. На Android иногда помогает установка новой версии поверх или очистка кэша лаунчера, на macOS — перезапуск Dock/Finder.
