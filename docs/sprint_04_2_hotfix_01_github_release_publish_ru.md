# Sprint 4.2 Hotfix 01 — публикация GitHub Release

## Проблема

Job `Publish GitHub Release` падал на шаге `Publish or update release` с ошибкой:

```text
fatal: not a git repository (or any of the parent directories): .git
```

Причина: release-job скачивал артефакты, но не делал `actions/checkout`, поэтому `gh release` не имел контекста репозитория. Это особенно проявлялось при создании тега/релиза через веб-интерфейс GitHub.

## Исправление

В `.github/workflows/build_installers.yml` добавлено:

- `actions/checkout@v6` в job `github-release`;
- явная передача репозитория через `GH_REPO` и флаг `--repo "$GITHUB_REPOSITORY"` для команд `gh release view/upload/edit/create`.

Теперь публикация release не зависит от текущей рабочей директории и должна работать как при `git push origin v...`, так и при создании тега через GitHub UI.

## Проверка

Создайте новый тег через GitHub UI или командой:

```bash
git tag v0.1.1-test
git push origin v0.1.1-test
```

После завершения workflow в `Repository → Releases` должны появиться Android/macOS-файлы и checksum-файлы.
