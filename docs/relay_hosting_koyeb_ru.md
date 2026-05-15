# Развёртывание ReadArc Relay на Koyeb

Этот документ описывает самый простой временный способ получить публичный relay без своего VPS.

Relay по-прежнему не является облачным хранилищем: он держит rooms, online peers и последние metadata snapshots только в памяти процесса. Книги передаются transit-сообщениями и не пишутся на диск.

## Что уже подготовлено

Файлы:

```text
server/rendezvous_relay/Dockerfile
server/rendezvous_relay/Procfile
docker-compose.yml
```

Koyeb может собрать FastAPI-приложение из GitHub-репозитория. Для нашего случая удобнее использовать Dockerfile из папки `server/rendezvous_relay`.

## Вариант A: Koyeb через Dockerfile

1. Зарегистрируйтесь или войдите в Koyeb.
2. Нажмите **Create Web Service**.
3. Выберите GitHub repository с проектом ReadArc.
4. В настройках build/deploy укажите:

```text
Root directory: server/rendezvous_relay
Dockerfile: Dockerfile
Port: 8787
```

5. Добавьте переменную окружения, если платформа просит порт явно:

```text
PORT=8787
```

6. После deploy откройте URL вида:

```text
https://your-service-name.koyeb.app/health
```

Ожидаемый ответ:

```json
{"ok": true, "rooms": {}}
```

7. В приложении ReadArc откройте:

```text
Синхронизация → Relay endpoint → Свой relay
```

И вставьте base URL:

```text
https://your-service-name.koyeb.app
```

## Вариант B: собрать приложение с endpoint по умолчанию

После того как Koyeb URL известен, можно больше не вводить его вручную в приложении. Есть два способа.

### Через GitHub Actions manual input

1. Откройте **Actions**.
2. Запустите **Build installable packages** вручную.
3. В поле `default_relay_url` вставьте:

```text
https://your-service-name.koyeb.app
```

4. Скачайте новые APK/DMG/PKG.
5. В приложении выберите режим:

```text
ReadArc relay
```

### Через GitHub repository variable

В репозитории:

```text
Settings → Secrets and variables → Actions → Variables → New repository variable
```

Создайте переменную:

```text
READARC_DEFAULT_RELAY_URL=https://your-service-name.koyeb.app
```

После этого обычные сборки будут компилировать этот URL в приложение.

## Важные ограничения free-hosting

- Relay использует WebSocket, поэтому платформа должна поддерживать долгоживущие соединения.
- Free-tier может иметь лимиты CPU/RAM/трафика и условия могут измениться.
- Для больших книг JSON/base64 chunks создают overhead; это нормально для MVP, но production должен перейти на binary frames/resume/P2P fallback.
- Если инстанс перезапускается, RAM-cache metadata snapshots очищается; устройства повторно отправят snapshots после подключения.

## Проверка Mac ↔ Android

1. Подключите Mac к Koyeb URL.
2. Подключите Android к тому же Koyeb URL.
3. Используйте одинаковый `accountId`, пока pairing ещё MVP.
4. Добавьте книгу на Mac.
5. Проверьте, что Android увидел книгу.
6. На Android нажмите скачать.
7. Убедитесь, что SHA-256 проверка прошла и книга стала локальной.

## Следующий шаг

После публичного relay следующий спринт — убрать ручной `accountId` через pairing-код/QR.
