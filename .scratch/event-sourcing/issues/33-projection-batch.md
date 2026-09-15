# 33: Проекция: объявление и синхронная пачка (`run_once`, `run_until_idle`)

**What to build:** автор проекции объявляет `use Core.Es.Projection, name:, events:, version:` с `project/1` и
`clear/0` и строит read-модель из событий state-stored и event-sourced агрегатов в порядке глобальной позиции. В этом
тикете проекция прогоняется синхронно — `Core.Es.Projection.run_once/2` и `Core.Es.Projection.Test.run_until_idle/2`;
read-модель и чекпоинт меняются в одной транзакции.

**Blocked by:** [25: Апкаст событий](25-event-upcasts.md),
[28: State-stored агрегат на общей таблице событий](28-state-stored-on-shared-event-table.md),
[31: Write-репозиторий event-sourced агрегата](31-event-sourced-repo.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Проекции: объявление, пачка, ожидание,
пересборка», ADR-0009

- [x] `use Core.Es.Projection, name:, events:, version:` (+ `repo:`, `codec:` из `Core.Config`): `CompileError` на
      модуль события, у кодека которого нет `type:`, на семейство `Agg.Event` в `events:`, на `version:` не целое ≥ 1;
      `project/1` и `clear/0` обязательны.
- [x] `Core.Es.Migration` создаёт `es_checkpoints`: строка на имя проекции — позиция `(xid, номер)`, версия, цель.
- [x] Чтение по глобальной позиции: типы агрегатов из `events:`,
      `xid < pg_snapshot_xmin(pg_current_snapshot()) OR xid = pg_current_xact_id_if_assigned()`, порядок `(xid, номер)`.
- [x] Тег — после цепочки `upcasts:`: объявленный → `load` и `project/1`; известный кодеку, но не объявленный → пропуск
      без `load`, чекпоинт продвигается; неизвестный кодеку → ошибка без продвижения.
- [x] Пачка — транзакция `DAO` до `batch_size`: `pg_try_advisory_xact_lock(имя)` (не получен — `:locked`) → строка
      чекпоинта (нет — `clear/0` и чекпоинт в начало со своей версией, `:processed`) → `project/1` на каждое событие →
      CAS `WHERE position = прочитанная` (0 строк — откат); событий нет — `:idle`.
- [x] Ошибка или исключение в `project/1` / `clear/0` — откат и `{:error, Error.t()}`; исключение — прикладная
      `%Error{}` с именем модуля исключения в `detail`, без текста.
- [x] `run_once(projection, opts \\ [])` → `:processed | :idle | :locked | {:error, Error.t()}`, `batch_size:` по
      умолчанию 100; внутри `Transact.run` — `raise`. `Core.Es.Projection.Test.run_until_idle(projection | [projection],
      opts \\ [])` → `:ok | {:error, :locked | Error.t()}` — `run_once` до `:idle` без предела итераций.
- [x] `Core.Otel.Es.project(projection_name, version, fun)` — корневой span `"project <имя>"`, `kind: :internal`,
      только на пачку с работой: `core.es.projection.name` / `.version` / `.reset`, `core.es.batch.event_count`,
      `core.es.checkpoint.from` / `.to` в виде `"<xid>/<номер>"`; при ошибке — `core.es.event.id` и `record_error/1`.
- [x] `Core.EsFixture.Projection` по событиям `Core.EsFixture.Account` и state-stored `Entity`, объявляет не все теги.
      Тесты на `Core.DataCase`, `async: false`: запись через репозитории → `run_until_idle` → read-модель; пропуск
      необъявленного тега; ошибка на событии не сдвигает чекпоинт и не теряет предыдущие; второе соединение получает
      `:locked`; span через `Core.OtelFixture`.
- [x] Новый свод `22-projections.md` («Объявление»; «Read-модель»: MUST NOT внешних эффектов, таблицу MUST писать одна
      проекция, ReadRepo MAY читать несколько) + skill `projections` + строки в картах `00-index.md` и `AGENTS.md`.
- [x] `13-repos.md` «Слои и пути» — проекция рядом с ReadRepo своей read-модели; `14-events-outbox.md`
      «Идемпотентность потребителей» — реакция с внешним эффектом — подписчик брокера, не проекция; `19-testing.md` —
      «Проекции» (SHOULD запись → `run_until_idle` → ReadRepo; MAY прямой `project/1` в `async: true`; прогон —
      `async: false`); `21-observability.md` — `Core.Otel.Es` в словарях, span только на пачку с работой, MUST NOT
      хранить контекст трейса в `es_events`.
- [x] `CHANGELOG.md`: «Новое» — проекции; строка `22-projections.md` в таблицы «Файл библиотеки» сводов потребителей.
- [x] `make` зелёный, включая `rules-check`.

## Comments

- 2026-09-14 — реализация:
  - кодек модуля события — `<Aggregate>.Event.Codec` по раскладке `11-domain.md` (прецедент конвенции —
    ADR-0006): у события нет ссылки на кодек, а `Core.Config` на компиляции читать нельзя. Модуль-ссылка
    «событие → кодек» из `use Core.Es.Event.Codec` отвергнута: тесты кодека объявляют дополнительные кодеки на
    те же события, и ссылка переопределялась бы в рантайме. `Core.EventFixture.Codec` переименован в
    `Core.EventFixture.Event.Codec`;
  - `es_checkpoints`: PK `name`, `xid` / `number`, `version`, `target_xid` / `target_number`, CHECK попарной
    `NULL`; цель здесь пишется `NULL` — её вычисляет пересборка (34); `down/0` удаляет таблицу через
    `drop_if_exists`, чтобы база со старой миграцией цикла откатывалась;
  - версия строки чекпоинта до чтения событий не сверяется — ветки `:outdated` и сброса на версии ниже
    остаются тикету 34; CAS идёт по прочитанной строке целиком (позиция и версия);
  - модули: `Core.Es.Projection` (объявление, `run_once/2`), `.Batch` (транзакция пачки), `.Checkpoint`
    (блокировка и SQL строки), `.Test`; чтение по позиции — `@doc false` `Core.Es.Store.list_after/4` на `repo:`
    проекции, а не на `Core.Config.dao/0`: иначе чтение ушло бы мимо транзакции пачки;
  - блокировка — `pg_try_advisory_xact_lock(hashtext('core.es.projection'), hashtext(name))`: пара ключей не
    пересекается с bigint-ключами `Core.Helper.Lock`;
  - корневой span — новый `Core.Otel.root_span/3`; `core.es.checkpoint.to` ставится только после CAS, у старта
    с начала позиций нет — атрибуты не ставятся;
  - сверх пунктов: текст исключения колбэка — `Logger.warning` внутри span'а (тикет 19: текст — в warning,
    связанном с трейсом); CAS без строки — прикладная `:checkpoint_conflict`; `CompileError` на повтор в
    `events:` и на два кодека одного типа агрегата; `run_once` внутри транзакции — `ArgumentError`;
  - `macro_config_test` — `use Core.Es.Projection` без `dao` / `codec`; `10-architecture.md` — `Es.Projection` в
    списке макросов; `12-errors.md` — ошибки пачки в источниках; README — `es_checkpoints`; описания skill
    `testing` и `observability`.
- 2026-09-14 — по ревью:
  - `Error.app/1` вместо `/2` на прямых call site'ах; `12-errors.md` отсылает к moduledoc `Core.Es.Projection`, а не
    к своду; `14-events-outbox.md` — строка-ссылка на `22-projections.md`; у норм `22-projections.md` — примеры
    «плохо» (имя из модуля, две проекции на таблицу, другая база); `positioned/1` собирает конверт через
    `Es.Store.Schema.to_wire/1`;
  - `:checkpoint_conflict` проверяется через `run_once` — проекция-фикстура двигает свою строку чекпоинта в
    `project/1`, — а не прямым вызовом `Checkpoint.move/3`;
  - конвенция кодека события `<Aggregate>.Event.Codec` записана в `spec.md`, раздел «Проекции»; её же ждёт тикет 37
    («тип из кодека события»); «кодек без `type:`» достижим только у модуля `<Aggregate>.Event.Codec`, собранного
    не через `use Core.Es.Event.Codec`, — его и проверяет тест;
  - оставлено: `Logger.warning` с текстом исключения внутри span'а пачки (тикет 19: текст — в warning, связанном с
    трейсом); тикет 35 при своём `warning` на попытку retry текст исключения не повторяет. Нормы `22-projections.md`
    сверх перечня тикета (без catch-all, `clear/0` по всем таблицам, та же база, что `es_events`) выводятся из
    ADR-0009, ADR-0011 и тикета 37. Коллизия `hashtext` двух имён делит блокировку без потери корректности (CAS) —
    описана у `@lock_sql`; пара `projection` / `declaration` в `Batch` не сворачивается в одну структуру.
