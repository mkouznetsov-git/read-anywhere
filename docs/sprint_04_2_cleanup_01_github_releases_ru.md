# Sprint 4.2 cleanup 01 — GitHub Releases для установочных файлов

## Зачем

GitHub Actions artifacts удобны для проверки CI, но скачивать тестовые сборки приложения из них не всегда удобно: artifacts лежат внутри конкретного workflow run, имеют ограниченный срок хранения и могут скачиваться медленнее.

Теперь при публикации git-тега вида `v*` workflow автоматически создаёт или обновляет GitHub Release и прикрепляет к нему installable-файлы.

## Как опубликовать тестовую версию

После успешной проверки кода выполните локально:

```bash
git tag v0.1.0-test
git push origin v0.1.0-test
```

Или для следующей версии:

```bash
git tag v0.1.1
git push origin v0.1.1
```

После push тега GitHub Actions выполнит:

```text
tests
  → Android release APKs and AAB
  → macOS release DMG and PKG
  → Publish GitHub Release
```

## Где скачать

После завершения workflow откройте:

```text
GitHub repository → Releases → нужный тег
```

В релизе будут приложены:

```text
Android:
  ReadAnywhere-...-android-arm64-v8a-release.apk
  ReadAnywhere-...-android-armeabi-v7a-release.apk
  ReadAnywhere-...-android-x86_64-release.apk
  ReadAnywhere-...-android-release.aab
  ReadAnywhere-android-release-SHA256SUMS.txt

macOS:
  ReadAnywhere-...-macos-release.dmg
  ReadAnywhere-...-macos-release.pkg
  ReadAnywhere-...-macos-release-app.zip
  ReadAnywhere-macos-release-SHA256SUMS.txt
```

Для большинства современных Android-телефонов нужен `arm64-v8a` APK.

## Повторная публикация одного тега

Если workflow запускается повторно для уже существующего тега, release job не падает: он обновляет release notes и перезаливает assets с `--clobber`.

Для полного пересоздания тега локально:

```bash
git tag -d v0.1.0-test
git push origin :refs/tags/v0.1.0-test
git tag v0.1.0-test
git push origin v0.1.0-test
```

## Что осталось для production

Эта автоматизация создаёт удобные тестовые релизы. Для production позже нужны:

```text
Android signing keystore
macOS Developer ID signing
macOS notarization
семантическое версионирование
release notes из changelog
```
