# 37: `Core.Es.ProjectionCase`: полнота `project/1` и `clear/0`

**What to build:** автор проекции пишет `use Core.Es.ProjectionCase, projection: MyProjection` и получает проверку, что
у `project/1` есть клауза на каждый объявленный модуль событий и что `clear/0` очищает каждую таблицу, которую пишет
проекция, — на golden-фикстурах событий, без ручного перечня таблиц.

**Blocked by:** [33: Проекция: объявление и синхронная пачка](33-projection-batch.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Тестовая поддержка в `lib/`»

- [ ] `use Core.Es.ProjectionCase, projection:, fixtures:` в `lib/`, ExUnit только внутри `quote`, свой sandbox
      checkout на `Core.Config.dao()`, `async: false`.
- [ ] Фикстура модуля — `<тип из кодека события>/<текущий тег>.json` от корня `fixtures:` (по умолчанию
      `test/support/fixtures/events`); нет фикстуры — провал с модулем и путём; источники `upcasts:` не прогоняются.
- [ ] Полнота `project/1`: фикстура каждого модуля `events:` в savepoint с откатом; провал — только
      `FunctionClauseError` самой `P.project/1`.
- [ ] `clear/0`: разница `n_tup_ins + n_tup_upd + n_tup_del` в `pg_stat_xact_user_tables` вокруг `project/1` на всех
      фикстурах (savepoint на каждую, ошибка откатывается) → `clear/0` → у каждой найденной таблицы `count(*) = 0`;
      пустой набор таблиц — провал.
- [ ] Логика проверок — функции `@doc false` → `:ok | {:error, detail}`; сгенерированный `test` делает
      `assert :ok = …`; библиотека вызывает их на сломанных проекциях `test/support`: нет клаузы, `clear/0` с забытой
      таблицей, нет фикстуры.
- [ ] `use Core.Es.ProjectionCase, projection: Core.EsFixture.Projection` проходит.
- [ ] `19-testing.md` — «Case-модули» + `Core.Es.ProjectionCase`, раздел «Проекции». `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
