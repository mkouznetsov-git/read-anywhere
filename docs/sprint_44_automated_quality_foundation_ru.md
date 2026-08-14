# Sprint 44 — Automated Quality Foundation

## Цель

Снять с ручной приёмки повторяющиеся проверки сборки и регрессий ReadArc. Любая функциональная ветка должна проходить автоматический quality gate до передачи сборки человеку.

## Новый цикл разработки

1. Изменения выполняются в отдельной ветке.
2. Открывается pull request в `main`.
3. GitHub Actions запускает unit/regression проверки и application smoke tests на Android и macOS.
4. Логи сохраняются в workflow artifacts.
5. Неуспешный PR не считается release candidate.
6. Ручная проверка остаётся финальным слоем для визуальной точности документов и реального hardware UX.

## Автоматические уровни Sprint 44

### Quality gate

`scripts/quality_gate.sh` выполняет:

- `bash -n` всех shell scripts;
- `py_compile` relay;
- запрет старого ReadAnywhere naming в активном коде;
- `flutter pub get`;
- `flutter analyze` (warnings/info пока не fatal, analyzer errors fatal);
- полный `flutter test`, включая regression contracts.

Логи складываются в `test-results/`.

### Regression contracts

`test/regression_contract_test.dart` фиксирует функции, которые уже были успешно восстановлены и которые нельзя случайно сломать несвязанным спринтом:

- рабочий backend QR scanner — `qr_code_scanner_plus`;
- CAMERA/INTERNET Android permissions;
- 6-значный pairing UX;
- relay connectivity guard для скачивания;
- наличие маршрутов PDF/DJVU/EPUB/FB2/TXT/DOCX/DOC;
- отсутствие ReadAnywhere naming в активном коде.

Это намеренно простые, жёсткие contracts: если следующая задача хочет изменить один из них, изменение должно быть сознательным и сопровождаться обновлением regression test.

### Cross-platform application smoke test

`integration_test/app_smoke_test.dart` запускает настоящий `ReadArcApp` и проверяет, что:

- приложение создаёт `MaterialApp`;
- библиотека открывается;
- старт не порождает Flutter framework exception.

CI запускает smoke test отдельно на Android emulator и macOS runner.

### Fixture policy

`test/fixtures/README.md` фиксирует набор будущих маленьких канонических документов. Большие пользовательские книги не должны становиться скрытой зависимостью CI; каждый сложный production bug превращается в маленький воспроизводимый fixture.

## GitHub Actions

Новый workflow `.github/workflows/quality_gate.yml` содержит три jobs:

1. `quality` — статические/unit/regression проверки;
2. `android-smoke` — запуск приложения на Android emulator;
3. `macos-smoke` — запуск приложения на macOS.

Логи каждого слоя загружаются как artifacts на 14 дней.

## Что Sprint 44 пока не автоматизирует полностью

- реальное оптическое считывание QR физической камерой;
- pixel-perfect DOCX/EPUB golden comparison;
- установка новой версии поверх предыдущей с проверкой сохранения реальной библиотеки;
- end-to-end sync двух процессов через relay;
- device farm на реальных Android-моделях.

Это следующие уровни quality platform. Текущий Sprint 44 сначала создаёт стабильный обязательный фундамент, чтобы новые тесты добавлялись без изменения основного CI-подхода.

## Обязательное правило регрессии

Каждый следующий спринт должен:

1. не ослаблять существующие regression contracts без явной причины;
2. добавлять regression test для исправленного серьёзного бага;
3. проходить `quality`, `android-smoke`, `macos-smoke`;
4. в описании PR перечислять функциональность, которая уже работала и не должна была измениться.

## Relay

Sprint 44 не меняет relay protocol и не требует SSH deployment relay.
