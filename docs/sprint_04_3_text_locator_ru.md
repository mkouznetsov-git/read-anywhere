# Sprint 4.3 — корректный TXT locator между устройствами

## Проблема

В предыдущих сборках приложение синхронизировало `progressPercent`, но TXT-reader восстанавливал позицию через scroll offset:

```text
locator = txt-scroll:<pixels>
restore = maxScrollExtent * progressPercent
```

Это плохо работает между разными устройствами, потому что `maxScrollExtent` зависит от ширины экрана, размера окна, шрифтов, высоты строк и платформенного layout. Поэтому процент мог совпадать, а фактическое место чтения отличалось.

## Решение

Для TXT добавлен content-based locator:

```json
{
  "type": "txt-char-v1",
  "charIndex": 12345,
  "totalChars": 500000,
  "chunkIndex": 5,
  "chunkCount": 200,
  "progressPercent": 2.469,
  "updatedAt": "..."
}
```

Теперь основной источник истины — позиция в нормализованном тексте, а не пиксельный scroll offset.

## Что изменилось

- TXT разбивается на более мелкие стабильные чанки примерно по 2500 символов.
- При чтении приложение определяет верхний видимый фрагмент и оценивает `charIndex` внутри него.
- В manifest и sync snapshot сохраняется JSON locator `txt-char-v1`.
- При открытии книги на другом устройстве reader восстанавливает позицию по `charIndex`.
- Старые locator-ы вида `txt-scroll:*` не ломают приложение: если JSON locator ещё нет, используется fallback по `progressPercent`.
- Исправлен decoder Windows-1251: раньше не-ASCII символы могли дублироваться при fallback-декодировании.

## Ограничения MVP

Это всё ещё TXT-only locator. Для EPUB/PDF/FB2/DJVU/DOCX нужны format-specific locators:

```text
EPUB: CFI / spine item + offset
PDF: page + normalized page position
FB2: section/chapter + text offset
DJVU: page + normalized page position
DOC/DOCX: converted document locator + original file id
```

## Проверка

1. Обновить оба клиента до этой сборки.
2. Открыть один и тот же TXT на Mac.
3. Пролистать примерно до середины видимой главы/абзаца.
4. Подождать 1–2 секунды, чтобы progress сохранился и sync ушёл на другое устройство.
5. Открыть эту книгу на Android.
6. Проверить, что книга открылась рядом с тем же текстовым фрагментом, а не просто рядом с тем же процентом.

Важно: первый переход со старой сборки может один раз восстановиться по старому проценту. После любого нового скролла в обновлённой сборке будет сохранён новый `txt-char-v1` locator.
