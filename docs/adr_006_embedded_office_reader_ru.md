# ADR 006 — Embedded Office reader для DOC/DOCX

## Решение

ReadArc должен открывать Office-документы встроенными модулями, без обязательных внешних приложений и серверных конвертеров.

## DOCX

DOCX — OOXML ZIP-контейнер. ReadArc разбирает его локально:

- `word/document.xml`;
- relationships;
- media assets;
- tables;
- headers/footers;
- footnotes/endnotes/comments.

Такой путь соответствует продуктовой цели: пользователь устанавливает ReadArc и сразу читает файл.

## DOC

Legacy `.doc` — CFB/OLE binary format. Sprint 40 добавляет embedded CFB parser и извлечение текста из ключевых stream-ов. Это не shell-wrapper над LibreOffice/antiword, а код внутри приложения.

## Почему не внешний конвертер

Внешние зависимости вроде LibreOffice, antiword, brew/apt/choco или серверной подготовки нарушают целевой UX ReadArc. Они могут быть полезны для внутренних экспериментов, но не должны быть обязательной частью пользовательского сценария.

## Следующий шаг

Если тестовые `.doc` файлы покажут недостаточное качество, нужно развивать отдельный native Office engine: разбор FIB/piece table, стили, таблицы и embedded objects. DOCX при этом уже остаётся на встроенном OOXML path.
