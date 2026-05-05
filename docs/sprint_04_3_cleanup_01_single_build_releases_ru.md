# Sprint 4.3 cleanup 01 — релизы без двойной сборки

## Проблема

Раньше обычный `push` в `main` запускал долгую сборку Android/macOS artifacts, а затем создание нового GitHub Release запускало такую же сборку второй раз. Это давало дубли Actions artifacts и заставляло ждать дважды.

## Решение

Workflow теперь публикует GitHub Release в том же запуске, в котором уже собраны release artifacts.

### Push в `main` / `master`

При каждом push выполняется:

```text
Tests → Android release artifacts → macOS release artifacts → Publish GitHub Release
```

GitHub Release публикуется как rolling prerelease:

```text
main-latest
```

Этот релиз обновляется при каждом push в `main` или `master`. Тег `main-latest` автоматически переносится на текущий commit.

### Push тега `v*`

Для версионного релиза можно создать тег:

```text
v0.1.2-test
```

Тогда workflow соберёт artifacts один раз и опубликует versioned GitHub Release с этим тегом.

### Ручной запуск

В `Actions → Build installable packages → Run workflow` добавлены поля:

```text
publish_release
release_tag
release_prerelease
```

Если `publish_release=true`, workflow опубликует GitHub Release из этого же запуска. Если `release_tag` пустой, будет использован `main-latest`.

## Что изменилось технически

- Actions artifacts теперь хранятся 7 дней, чтобы не копить лишний объём.
- GitHub Releases используются как основное место скачивания тестовых APK/DMG/PKG.
- Для rolling-релиза `main-latest` workflow переносит одноимённый tag на текущий commit и перезаливает release assets с `--clobber`.

## Рекомендованный процесс разработки

Обычная разработка:

```text
push в main → дождаться CI → скачать файлы из Releases → main-latest
```

Тестовая версия с номером:

```text
создать tag v0.1.2-test → дождаться CI → скачать файлы из Releases → v0.1.2-test
```

Для повседневного тестирования используйте `main-latest`, а numbered tags оставляйте для контрольных точек.
