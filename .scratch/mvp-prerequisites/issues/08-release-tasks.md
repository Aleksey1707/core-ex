# 08: Задачи релиза — миграции и requeue outbox

**What to build:** оператор на релизе без Mix прогоняет миграции всех репозиториев приложения, откатывает
миграцию и возвращает `:failed` записи outbox в доставку.

Спека — «Эксплуатация».

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `Core.Release.migrate(app)` — все `up`-миграции каждого репозитория из `:ecto_repos` приложения.
- [x] `Core.Release.rollback(app, repo, version)` — откат до версии.
- [x] `Core.Outbox.Release.requeue/1` (`:all` или список id) над `requeue_failed`, итог — число записей. Образец —
      `Core.Mq.Dlq.Release.requeue/2`.
- [x] Вывод оператору — по норме задач релиза в `20-agreements.md`.
- [x] Тесты:
      - `migrate` и `rollback` на миграции с отдельной тестовой версией (номер вида `20_261_…`);
      - `requeue` по образцу тестов `Core.Mq.Dlq.Release`.
- [x] App-ярус задач релиза: какие задачи даёт библиотека и как их зовёт `bin/<app> eval`.
- [x] CHANGELOG «Новое».
- [x] `make` зелёный.
