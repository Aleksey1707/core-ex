# 37: `Core.Es.ProjectionCase`: полнота `project/1` и `clear/0`

**What to build:** автор проекции пишет `use Core.Es.ProjectionCase, projection: MyProjection` и получает проверку, что
у `project/1` есть клауза на каждый объявленный модуль событий и что `clear/0` очищает каждую таблицу, которую пишет
проекция, — на golden-фикстурах событий, без ручного перечня таблиц.

**Blocked by:** [33: Проекция: объявление и синхронная пачка](33-projection-batch.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Тестовая поддержка в `lib/`»

- [x] `use Core.Es.ProjectionCase, projection:, fixtures:` в `lib/`, ExUnit только внутри `quote`, свой sandbox
      checkout на `Core.Config.dao()`, `async: false`.
- [x] Фикстура модуля — `<тип из кодека события>/<текущий тег>.json` от корня `fixtures:` (по умолчанию
      `test/support/fixtures/events`); нет фикстуры — провал с модулем и путём; источники `upcasts:` не прогоняются.
- [x] Полнота `project/1`: фикстура каждого модуля `events:` в savepoint с откатом; провал — только
      `FunctionClauseError` самой `P.project/1`.
- [x] `clear/0`: разница `n_tup_ins + n_tup_upd + n_tup_del` в `pg_stat_xact_user_tables` вокруг `project/1` на всех
      фикстурах (savepoint на каждую, ошибка откатывается) → `clear/0` → у каждой найденной таблицы `count(*) = 0`;
      пустой набор таблиц — провал.
- [x] Логика проверок — функции `@doc false` → `:ok | {:error, detail}`; сгенерированный `test` делает
      `assert :ok = …`; библиотека вызывает их на сломанных проекциях `test/support`: нет клаузы, `clear/0` с забытой
      таблицей, нет фикстуры.
- [x] `use Core.Es.ProjectionCase, projection: Core.EsFixture.Projection` проходит.
- [x] `19-testing.md` — «Case-модули» + `Core.Es.ProjectionCase`, раздел «Проекции». `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - `async:` — необязательная опция, допускается только `false`, `true` — `CompileError`: Credo
    `PassAsyncInTestCases` требует явный `async:` у любого `use …Case` в тест-файле;
  - sandbox checkout — на `repo:` проекции (`__es_projection__().dao`), по умолчанию это `Core.Config.dao()`: пачка
    пишет туда же;
  - каждая проверка идёт в `Transact.run` с откатом, savepoint'ы на фикстуру (`Core.Helper.Savepoint`) — внутри:
    в sandbox вне явной транзакции Postgrex оборачивает каждый запрос своим savepoint и снимает вложенные.
    Статистика `pg_stat_xact_user_tables` считает и попытки откаченных savepoint'ов, поэтому таблица, запись в
    которую откатил отказ клаузы, в набор попадает;
  - фикстуры грузят обе проверки, отдельного теста нет: нет файла — `%{missing: [{path, mod}]}`, файл не
    грузится или в `type` не текущий тег модуля — `%{failed: [{path, reason}]}` (`%{type: _}`, как у
    `Core.Es.EventCompatCase`);
  - detail `check_clear/2`: `%{tables: []}`, `%{clear: error}` на `{:error, _}` колбэка (исключение `clear/0` не
    ловится), `%{not_cleared: [{"схема.таблица", count}]}`;
  - `Core.EsFixture.BrokenProjection` — без клаузы `Closed`, `clear/0` забывает таблицу названий, `Renamed` падает
    `FunctionClauseError` приватной функции; таблицы — миграция `20260914145000_create_broken_projection_fixture` (`20260914150000` занята тестовой миграцией
    `delete_checkpoint` в `projection_test.exs`).
    Проекции без записи и с отказом `clear/0` — модули в `projection_case_test.exs`;
  - предел: таблица, которую `project/1` на фикстурах не трогает (`UPDATE` строки, которой нет), в набор не
    попадает — записано в moduledoc;
  - сверх пунктов: «Проверяется» в `22-projections.md`, ссылка в «Golden-фикстурах» `14-events-outbox.md`,
    moduledoc `Core.Es.Projection`, `description` skills `testing` и `projections`, спека.
- 2026-09-14 — по ревью:
  - фикстура сверялась по модулю загруженного события — фикстура источника `upcasts:` под текущим именем прошла бы
    апкастом; теперь тег `type` сверяется с текущим, причина `%{type: _}`;
  - «Проекции» в `19-testing.md` — норма и ссылки, без пересказа проверок `22-projections.md` и устройства case;
    пункт CHANGELOG без внутренностей savepoint'ов и формулы статистики;
  - имена: `ensure_sync!`, `written_tables`, `project_or_error`, `table_writes`, `check_clear_result`;
  - версия миграции фикстуры сменена на `20260914145000`: `20260914150000` занята тестовой миграцией
    `delete_checkpoint` в `projection_test.exs` (`make` падал на `:already_up`);
  - оставлено: общий модуль проверок с `Core.Es.EventCompatCase` (`*_clause?`, загрузка фикстуры) — вне задачи;
    `projects?` зеркалит `evolves?`; `throw` / `exit` из клаузы и возврат `project/1` вне контракта роняют тест, а
    не откатываются — видно и так; `Silent` / `Uncleared` в тест-файле, как проекции в `projection_test.exs`.
