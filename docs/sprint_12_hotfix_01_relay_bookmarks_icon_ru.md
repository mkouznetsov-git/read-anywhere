# Sprint 12 Hotfix 01 — Relay disconnects, universal bookmarks and app icon

## Relay disconnect tracebacks

При отключении устройства WebSocket может закрыться между моментом выбора peer-а для broadcast и фактической отправкой `send_text`. Раньше такое закрытие могло попадать в лог uvicorn как полный traceback `ClientDisconnected` / `ConnectionClosedOK`.

Исправление:

- `_send_text_safely` теперь считает `WebSocketDisconnect`, `ClientDisconnected`, `ConnectionClosed*` штатным отключением клиента;
- stale peer удаляется из комнаты;
- relay не должен печатать большой traceback при обычных переподключениях, Tailscale/Funnel-обрывах и закрытии приложения.

Relay version: `0.1.6`.

## Закладки для всех текущих форматов

Закладки доступны для всех форматов, которые сейчас реально открывает приложение:

- TXT;
- FB2;
- PDF.

Для PDF добавлена кнопка закладки в обычном и полноэкранном режиме. Locator сохраняется как `pdf-page-v1`.

Для будущих форматов требование такое же: любой reader обязан отдавать текущий locator и иметь кнопку добавления закладки.

## Иконка приложения

Добавлена новая простая тёплая иконка ReadAnywhere:

- бежево-коричневая палитра;
- открытая книга;
- небольшой bookmark-ribbon.

Иконка лежит в `assets/app_icon` и копируется в Android/macOS platform folders после `flutter create` в `scripts/prepare_flutter_platforms.sh`.
