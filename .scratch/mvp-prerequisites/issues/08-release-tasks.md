# 08: Задачи релиза — миграции и requeue outbox

**What to build:** оператор на релизе без Mix прогоняет миграции всех репозиториев приложения, откатывает
миграцию и возвращает `:failed` записи outbox в доставку.

Спека — «Эксплуатация».

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `Core.Release.migrate(app)` — все `up`-миграции каждого репозитория из `:ecto_repos` приложения.
- [ ] `Core.Release.rollback(app, repo, version)` — откат до версии.
- [ ] `Core.Outbox.Release.requeue/1` (`:all` или список id) над `requeue_failed`, итог — число записей. Образец —
      `Core.Mq.Dlq.Release.requeue/2`.
- [ ] Вывод оператору — по норме задач релиза в `20-agreements.md`.
- [ ] Тесты:
      - `migrate` и `rollback` на миграции с отдельной тестовой версией (номер вида `20_261_…`);
      - `requeue` по образцу тестов `Core.Mq.Dlq.Release`.
- [ ] App-ярус задач релиза: какие задачи даёт библиотека и как их зовёт `bin/<app> eval`.
- [ ] CHANGELOG «Новое».
- [ ] `make` зелёный.
