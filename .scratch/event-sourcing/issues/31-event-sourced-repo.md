# 31: Write-репозиторий event-sourced агрегата: `get` / `get_many` / `append` / `refresh`

**What to build:** автор usecase исполняет команду event-sourced агрегата путём `Agg.Repo.get` → `Agg.execute/2` →
`Agg.Repo.append` в одном `Transact.run`: события пишутся в `es_events` вместе с записями outbox, а конкурентная запись
и устаревшая версия клиента дают `:version_mismatch`. Репозиторий объявляется `use Core.Es.Aggregate.Repo` /
`use Core.Es.Aggregate.Repo.Pg` и подменяется по конвенции `<Behaviour>.Pg`.

**Blocked by:** [26: Хранилище событий](26-event-store-append.md),
[30: Контракт event-sourced агрегата](30-event-sourced-aggregate-contract.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Write-репозиторий event-sourced агрегата»

- [x] `use Core.Es.Aggregate.Repo, aggregate:, id:` — behaviour: `get/4`, `get_many/3`, `append/3`, `refresh/4`.
- [x] `use Core.Es.Aggregate.Repo.Pg, behaviour:, aggregate:, id:, errors:, outbox:` (+ `repo:`, `codec:`); кодек
      событий — из `use Core.Es.Aggregate`; без `:version_mismatch` в `errors:` или без `outbox:` — `CompileError`;
      реализация резолвится по ADR-0006.
- [x] `get(id, :current, context)` на пустом потоке — `%Agg{id: id, version: nil}`; `%Version{}` мимо головы потока —
      `:version_mismatch` (на пустом — `actual: nil`); нечитаемый поток (неизвестный тег, разрыв, чужой `aggregate_id`)
      — `raise`.
- [x] `get_many` — один запрос, состояния в порядке пар, все расхождения — одна `:version_mismatch`, повтор id —
      `raise`.
- [x] `append([])` — `:ok` без запросов; иначе сам в `Transact.run(dao)`: `outbox.from_events` →
      `Core.Es.Store.append` с непрерывностью потока → `outbox_repo().append`; события нескольких потоков одного типа —
      конфликт в одном откатывает пачку; событие чужого типа — `FunctionClauseError`.
- [x] `refresh(state, version, context)` — хвост потока после `state.version` → `fold/2` → сверка `%Version{}`.
- [x] Контрактный набор behaviour в `test/support` прогоняется на `Account.Repo.Pg`: создание, цепочка команд без
      повторного `get`, пустой поток, устаревшая версия, конкурентная запись, откат пачки нескольких потоков, записи
      outbox в той же транзакции, `refresh` после записи в обход.
- [x] Telemetry `[:es, :aggregate, :load]` на вызов (`duration`, `streams`, `events`; `type`,
      `op: :get | :get_many | :refresh`, `result: :ok | :version_mismatch`) и `[:es, :aggregate, :fold]` на поток
      (`events`; `type`, `snapshot: :off`); span'а у восстановления нет.
- [x] `13-repos.md` — H2 «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»: пример `use`, `get` /
      `get_many` / `append` / `refresh`, один репозиторий в common-слое без `default_filters`, `Repo.Sc` и `delete`;
      MUST NOT `Core.Es.Store.append` дополнен вторым builder'ом. `20-agreements.md` — «Load/save в одной функции»:
      пример `get` → `Agg.execute/2` → `append`; исключения `@spec` — генерируемые функции builder'а. README, списки
      модулей `10-architecture.md`, `description` skill `repos`, `CHANGELOG.md` «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - чтение потока живёт в рантайме `Core.Es.Aggregate.Repo.Pg`, а не в `Core.Es.Store`: один запрос с `values/2`
    по парам «поток, версия после» обслуживает `get` / `get_many` / `refresh`, и у `repo:` / `codec:` builder'а есть
    смысл; `Core.Es.Store.append` по-прежнему пишет через `Core.Config.dao/0`;
  - `repo:` / `codec:` резолвятся `Core.Helper.Opts.module_or_config!/4` в приватной `es_aggregate_repo/0`
    модуля-потребителя — вызов `Core.Config` в рантайме, конфигурация на компиляции не нужна;
  - сверки на компиляции (кодек с `type:`, Prim агрегата кодека, событие outbox, clause `:version_mismatch`)
    вынесены из `Core.Repo.Pg.StateStored` в `Core.Es.Store.Opts` и общие у обоих builder'ов; тексты
    `CompileError` у `StateStored` не изменились; сверх тикета builder сверяет `id:` и событие `outbox:`;
  - detail `:version_mismatch` у чтения — та же форма `%{aggregate_id, expected, actual}`, что у `append`;
    у `get_many` — список в порядке пар; `get_many([])` — `{:ok, []}` без запросов, `[:es, :aggregate, :load]` с `streams: 0`;
  - контрактный набор — `Core.EsAggregateRepoContract` (`test/support`), хост — `test/core/es/aggregate/repo/pg_test.exs`;
    «один запрос» и «без запросов» проверяются счётчиком telemetry Ecto в процессе теста; сверх пунктов — тест
    непрерывности потока, проверенный мутацией `continuous?: false`;
  - сверх пунктов тикета: `12-errors.md` («Источники `%Error{}`»), кейс в `test/core/macro_config_test.exs`;
  - по ревью оставлено как есть: строки PromEx для `[:es, :aggregate, :*]` — вместе с `Core.Es.PromEx` (тикет 40);
    при `repo:`, отличном от `Core.Config.dao/0`, события и outbox пишутся мимо транзакции `repo:` — как у
    `Core.Repo.Pg.StateStored`, оговорено в moduledoc.
