# Контракт репозитория event-sourced агрегата

Type: grilling
Status: resolved
Blocked by: 05, 06, 12
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Какой write-репозиторий у event-sourced агрегата:

- переиспользовать behaviour `Core.Repo` (пресеты `:full` / `:permanent` / `:read`) или завести
  отдельный; какие чтения осмысленны без строки состояния — `get` по id и версии, а `list` / `page` /
  `find_many` по фильтрам?
- как проверяется `Version` на чтении и записи, во что превращается конфликт (`:version_mismatch`);
- роль `Repo.Sc` и `check_events_for_change!`, когда состояние меняется только событиями;
- что возвращает запись (ADR-0001: входной агрегат с очищенными `events`);
- где и в каком порядке идёт flush в event store и outbox; есть ли `delete`;
- как ложатся правило «load/save агрегата — в одной функции» и CQS (`docs/rules/20-agreements.md`).

## Answer

- **Запись — примитивы.** `<Agg>.Repo`: `get/4`, `get_many/3`, `append/3`. Usecase: `get` → `Agg.execute/2` →
  `append(events, context, opts \\ [])` → `:ok | {:error, _}`; на `[]` — `:ok` без запросов. Аргумент — только события;
  `execute` в репозитории и `save` → `{:ok, state}` отвергнуты: новое состояние отдаёт `execute/2`, ADR-0001 к
  event-sourced не применим.
- **Чтения.** `get!`, `list`, `page`, `count`, `exists?`, `exists_all?`, `find_many` нет: без строки состояния фильтровать
  нечего, отдача наружу — read-путь.
- **Версия.** `get` не отдаёт `:not_found`: пустой поток при `:current` — `%Agg{id: id, version: nil}`, `not_found` решает
  `decide`; `%Version{}` мимо версии потока, в том числе пустого, — `:version_mismatch` (`actual: nil`). На записи —
  версии событий: unique, страж `xid` и непрерывность потока (первая версия в пачке = `max + 1`, у пустого — 1) —
  `:version_mismatch`; версии не подряд внутри пачки — `raise`.
- **Нечитаемый поток** при свёртке (неизвестный тип, разрыв версий, чужой `aggregate_id`) — `raise`.
- **`Repo.Sc` не участвует:** `shadow_copy?` и аналога `check_events_for_change!` нет.
- **Пачка.** `get_many` — один запрос, состояния в порядке пар, все расхождения — одна `:version_mismatch`, повтор id —
  `raise`. `append` принимает события нескольких потоков одного типа агрегата, проверки — по потоку, конфликт в одном
  откатывает пачку; событие чужого типа — `FunctionClauseError`.
- **Порядок записи** — `append` сам в `Transact.run(dao)`: `outbox.from_events` → `Core.Es.Store.append` →
  `outbox_repo().append`.
- **Модули.** `use Core.Es.Aggregate.Repo, aggregate:, id:` и `use Core.Es.Aggregate.Repo.Pg, behaviour:, aggregate:,
  id:, errors:, outbox:` (+ `repo:`, `codec:`); кодек событий — из `use Core.Es.Aggregate`; `errors:` без
  `:version_mismatch` — `CompileError`; DI — `<Behaviour>.Pg`. Хранилище событий — модуль библиотеки `Core.Es.Store`,
  триплета `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` нет. `outbox:` обязателен, как у state-stored.
- **Размещение и доступ.** Один репозиторий на агрегат в `common/<aggregate>/`, без `default_filters` и role-обёрток;
  доступ — usecase (роли из `Context`) и `decide` (владение по состоянию и `by` команды).
- **`delete` нет:** удаление — доменное событие; физическое удаление и архивация потоков — Out of scope карты.
- **Load/save и CQS.** `get` / `get_many`, `Agg.execute/2` и `append` — в теле одной функции под одним `Transact.run`;
  `get` — запрос, `append` — команда; состояние из `execute/2` годится для следующего `execute` без повторного `get`.
- Не проверено на нагрузке: свёртка всего потока на каждом `get` (до снапшотов).
- ADR не заводится. `CONTEXT.md` — определение «Repo» (запись результата мутации: у event-sourced — только события).

## Comments

- 2026-09-13 — ограничения из тикета [«Своя реализация или готовая библиотека»](12-grilling-build-or-adopt.md):
  конфликт ожидаемой версии возвращает доменную ошибку `:version_mismatch` и не переводит транзакцию usecase в
  aborted (как `Es.Event.Repo.Pg.append/2`); запись не опирается на приватные API Ecto / ecto_sql.
- 2026-09-13 — ограничения из тикета [«Контракт event-sourced агрегата»](05-prototype-aggregate-contract.md):
  у состояния нет `events` — новые события отдаёт чистый шаг `Agg.execute/2` (`{:ok, {[Es.Event], состояние}}`),
  он вызывается между чтением и записью; на пути команды пустой поток — `%Agg{id: id, version: nil}`, а
  `not_found` решает `decide` (что отдаёт `get` вне команды — вопрос этого тикета); `id` и `version` состояния
  ведёт библиотека (`fold/2`).
- 2026-09-13 — ограничения из тикета [«Модель потока и таблица событий»](06-grilling-stream-model.md): события пишутся
  в общую таблицу `es_events` — ключ потока тип агрегата и `aggregate_id`, unique с версией, таблицы потоков нет;
  append отвергает запись в поток, где есть событие с `xid` больше `pg_current_xact_id()`, — `:version_mismatch`,
  в том числе когда usecase получил xid до чтения агрегата; `at` — секунды.
- 2026-09-13 — раунд 1:
  - запись — примитивы: usecase зовёт `get` → `Agg.execute/2` → `append(events, context, opts \\ [])` →
    `:ok | {:error, _}`, на `[]` — `:ok` без запросов; аргумент — только события; `execute` в репозитории и
    `save` → `{:ok, state}` отвергнуты; возврат глобальной позиции (read-your-writes) — вопрос тикета «Проекции»;
  - чтения — `get/4` и `get_many/3`; `get!`, `list`, `page`, `count`, `exists?`, `exists_all?`, `find_many` нет;
  - `get` не отдаёт `:not_found`: `:current` на пустом потоке — `%Agg{id: id, version: nil}`; `%Version{}` мимо
    версии потока, в том числе пустого, — `:version_mismatch` (`actual: nil`); на записи версия проверяется
    версиями событий (unique + страж `xid`), отдельной ожидаемой версии `append` не принимает;
  - нечитаемый поток при свёртке (неизвестный тип, разрыв версий, чужой `aggregate_id`) — `raise`;
  - `Repo.Sc` репозиторий не трогает, `shadow_copy?` и аналога `check_events_for_change!` нет;
  - хранилище событий — один модуль библиотеки над `es_events`; триплета `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` у
    event-sourced агрегата нет; история потока для экрана — read-путь;
  - `outbox:` обязателен, как у state-stored;
  - один репозиторий на агрегат в `common/<aggregate>/`, без `default_filters` и role-обёрток; доступ — usecase
    (роли из `Context`) и `decide` (владение по состоянию и `by` команды);
  - `delete` нет: удаление — доменное событие; физическое удаление и архивация потоков — Out of scope карты.
- 2026-09-13 — раунд 2:
  - `use Core.Es.Aggregate.Repo, aggregate:, id:` и `use Core.Es.Aggregate.Repo.Pg, behaviour:, aggregate:, id:, errors:,
    outbox:` (+ `repo:`, `codec:`); кодек событий — из `use Core.Es.Aggregate`; `errors:` без `:version_mismatch` —
    `CompileError`; DI — `<Behaviour>.Pg`; хранилище событий — `Core.Es.Store`;
  - `append` сам в `Transact.run(dao)`: `outbox.from_events` → `Core.Es.Store.append` → `outbox_repo().append`;
  - непрерывность потока на записи: первая версия потока в пачке = `max + 1` (пустой — 1), иначе `:version_mismatch`
    (`%{aggregate_id, expected, actual}`); версии не подряд внутри пачки — `raise`;
  - `get_many` — один запрос, состояния в порядке пар, все расхождения — одна `:version_mismatch`, повтор id — `raise`;
    `append` — события нескольких потоков одного типа, проверки по потоку, конфликт в одном откатывает пачку; чужой
    тип — `FunctionClauseError`;
  - load/save: `get` / `get_many`, `Agg.execute/2`, `append` — в одной функции под одним `Transact.run`; `get` —
    запрос, `append` — команда; состояние из `execute/2` годится для следующего `execute` без повторного `get`;
  - ADR не заводится.
