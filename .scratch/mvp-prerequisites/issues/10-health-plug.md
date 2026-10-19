# 10: `Core.Web.HealthPlug`

**What to build:** приложение отвечает на liveness без проверок. Readiness проверяет базу с таймаутом, поэтому
compose и балансировщик не шлют трафик приложению без базы.

Спека — «Эксплуатация», `HealthPlug`.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Опции: `repos:` (обязательная), `health_path:` (`/health`), `ready_path:` (`/ready`), `timeout:` (1000 мс).
      Неверные опции — ошибка на `init/1`.
- [x] `/health` — `200` `ok`.
- [x] `/ready` — `SELECT 1` по каждому репозиторию с таймаутом: `200` `ok` или `503` `unavailable` с `warning` в лог.
- [x] После ответа `halt`. Прочие пути проходят дальше без изменений.
- [x] Тесты через `Plug.Test`: `/health`, `/ready` при живом и недоступном репозитории, чужой путь.
- [x] App-ярус (web-обвязка, healthcheck) и CHANGELOG «Новое».
- [x] `make` зелёный.
