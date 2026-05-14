# Sprint 42A Hotfix 02 — восстановление запуска и видимого DOCX page layout

## Причина

После первого варианта Sprint 42A DOCX page renderer на части платформ мог уйти в пустую страницу из-за слишком сложной связки `OverflowBox` + runtime measurement + `Transform.scale`.
На macOS библиотека также могла бесконечно показывать spinner, если загрузка manifest зависала или падала без видимого сообщения.

## Исправления

- DOCX page scaling переведён на более безопасную модель `Align(widthFactor/heightFactor) + Transform.scale`.
- Убран runtime measurement widget из Office page renderer.
- На Android/iOS временно отключён `SelectionArea` вокруг масштабированной DOCX-страницы, чтобы документ гарантированно отрисовывался. Кнопка "Скопировать текст документа" сохранена.
- На desktop `SelectionArea` для DOCX сохранён.
- Сохранены атрибуты `<w:br ...>`, чтобы не терять `w:type="page"`.
- Загрузка библиотеки теперь имеет timeout и выводит диагностический экран с кнопкой повторить вместо бесконечного spinner-а.

## Что не менялось

- Relay не менялся.
- PDF / DJVU / EPUB / FB2 / TXT не менялись.
- GitHub Actions и версионирование сборок не менялись.

## Проверки

```bash
cd apps/flutter_client
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build macos --release
```

## Ручная проверка

1. Запустить macOS-приложение и убедиться, что библиотека либо открывается, либо показывает явную ошибку с кнопкой "Повторить", но не висит бесконечно.
2. Открыть `Договор_поставки.docx` на macOS.
3. Открыть тот же DOCX на Android.
4. Проверить, что страница видима, текст не исчезает, лист масштабируется по ширине экрана.
