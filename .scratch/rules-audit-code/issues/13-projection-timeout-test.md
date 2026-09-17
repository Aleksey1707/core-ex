# 13: Тест ответа 202 на таймаут проекции

**Status:** needs-triage

**What to build:** способ проверить в тесте ветку `:projection_timeout` / `:projection_rebuilding` при
тестовом дереве `await: :inline` (там таймаута нет, иной исход — `RuntimeError`) — например хелпер
`Core.Es.Projection.Test` для временного `await: :poll` с восстановлением; норма в `19-testing.md`, «Проекции».

**Why:** ветку 202 из `app/15-web-api.md`, «Ожидание проекции» приложение проверяет своим хелпером, который
перезапускает дерево проекций и правит env.
