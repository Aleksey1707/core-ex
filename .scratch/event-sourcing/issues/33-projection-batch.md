# 33: Проекция: объявление и синхронная пачка (`run_once`, `run_until_idle`)

**What to build:** автор проекции объявляет `use Core.Es.Projection, name:, events:, version:` с `project/1` и
`clear/0` и строит read-модель из событий state-stored и event-sourced агрегатов в порядке глобальной позиции. В этом
тикете проекция прогоняется синхронно — `Core.Es.Projection.run_once/2` и `Core.Es.Projection.Test.run_until_idle/2`;
read-модель и чекпоинт меняются в одной транзакции.

**Blocked by:** [25: Апкаст событий](25-event-upcasts.md),
[28: State-stored агрегат на общей таблице событий](28-state-stored-on-shared-event-table.md),
[31: Write-репозиторий event-sourced агрегата](31-event-sourced-repo.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Проекции: объявление, пачка, ожидание,
пересборка», ADR-0009

- [ ] `use Core.Es.Projection, name:, events:, version:` (+ `repo:`, `codec:` из `Core.Config`): `CompileError` на
      модуль события, у кодека которого нет `type:`, на семейство `Agg.Event` в `events:`, на `version:` не целое ≥ 1;
      `project/1` и `clear/0` обязательны.
- [ ] `Core.Es.Migration` создаёт `es_checkpoints`: строка на имя проекции — позиция `(xid, номер)`, версия, цель.
- [ ] Чтение по глобальной позиции: типы агрегатов из `events:`,
      `xid < pg_snapshot_xmin(pg_current_snapshot()) OR xid = pg_current_xact_id_if_assigned()`, порядок `(xid, номер)`.
- [ ] Тег — после цепочки `upcasts:`: объявленный → `load` и `project/1`; известный кодеку, но не объявленный → пропуск
      без `load`, чекпоинт продвигается; неизвестный кодеку → ошибка без продвижения.
- [ ] Пачка — транзакция `DAO` до `batch_size`: `pg_try_advisory_xact_lock(имя)` (не получен — `:locked`) → строка
      чекпоинта (нет — `clear/0` и чекпоинт в начало со своей версией, `:processed`) → `project/1` на каждое событие →
      CAS `WHERE position = прочитанная` (0 строк — откат); событий нет — `:idle`.
- [ ] Ошибка или исключение в `project/1` / `clear/0` — откат и `{:error, Error.t()}`; исключение — прикладная
      `%Error{}` с именем модуля исключения в `detail`, без текста.
- [ ] `run_once(projection, opts \\ [])` → `:processed | :idle | :locked | {:error, Error.t()}`, `batch_size:` по
      умолчанию 100; внутри `Transact.run` — `raise`. `Core.Es.Projection.Test.run_until_idle(projection | [projection],
      opts \\ [])` → `:ok | {:error, :locked | Error.t()}` — `run_once` до `:idle` без предела итераций.
- [ ] `Core.Otel.Es.project(projection_name, version, fun)` — корневой span `"project <имя>"`, `kind: :internal`,
      только на пачку с работой: `core.es.projection.name` / `.version` / `.reset`, `core.es.batch.event_count`,
      `core.es.checkpoint.from` / `.to` в виде `"<xid>/<номер>"`; при ошибке — `core.es.event.id` и `record_error/1`.
- [ ] `Core.EsFixture.Projection` по событиям `Core.EsFixture.Account` и state-stored `Entity`, объявляет не все теги.
      Тесты на `Core.DataCase`, `async: false`: запись через репозитории → `run_until_idle` → read-модель; пропуск
      необъявленного тега; ошибка на событии не сдвигает чекпоинт и не теряет предыдущие; второе соединение получает
      `:locked`; span через `Core.OtelFixture`.
- [ ] Новый свод `22-projections.md` («Объявление»; «Read-модель»: MUST NOT внешних эффектов, таблицу MUST писать одна
      проекция, ReadRepo MAY читать несколько) + skill `projections` + строки в картах `00-index.md` и `AGENTS.md`.
- [ ] `13-repos.md` «Слои и пути» — проекция рядом с ReadRepo своей read-модели; `14-events-outbox.md`
      «Идемпотентность потребителей» — реакция с внешним эффектом — подписчик брокера, не проекция; `19-testing.md` —
      «Проекции» (SHOULD запись → `run_until_idle` → ReadRepo; MAY прямой `project/1` в `async: true`; прогон —
      `async: false`); `21-observability.md` — `Core.Otel.Es` в словарях, span только на пачку с работой, MUST NOT
      хранить контекст трейса в `es_events`.
- [ ] `CHANGELOG.md`: «Новое» — проекции; строка `22-projections.md` в таблицы «Файл библиотеки» сводов потребителей.
- [ ] `make` зелёный, включая `rules-check`.
