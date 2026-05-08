# Sprint 17 Hotfix 01 — compile fix for EPUB HTML parsing

Исправлены ошибки компиляции в `lib/main.dart`, обнаруженные `compile_smoke_test.dart` в GitHub Actions:

- raw string с регулярными выражениями для `<img src="...">` и `<a href="...">` переведены на triple-quoted raw strings, чтобы корректно поддерживать и двойные, и одинарные кавычки в HTML-атрибутах;
- удалён дублирующий аргумент `overflow` у `Text`.

Функциональная логика Sprint 17 не менялась: direct/LAN transfer, EPUB rich MVP, DOC/DOCX/CHM/DJVU fallback и reconnect-loop сохранены.
