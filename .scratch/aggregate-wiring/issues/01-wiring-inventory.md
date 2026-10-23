# 01: Граф связей и компиляции сейчас

Type: task
Status: resolved

Blocked by: None

## Question

Как сейчас устроены связи event-sourced агрегата в восьми билдерах карты и в `Es.Event`? Нужна таблица, по
строке на билдер:

- опции связей `use` (`aggregate:`, `id:`, `event:`, `event_codec:`, `aggregate_id:`, `by:`, `repo:`,
  `behaviour:`, `events:`);
- что грузится при раскрытии `use` (`Code.ensure_compiled`, вызовы `__es_*__` / `__codec_*__`) и после
  (`@before_compile`, `@after_compile`);
- что из сгенерированного требует литерала модуля: головы, `@callback`, `@spec`, `@type`;
- кто сверяет опцию и чем (`Es.Store.Opts.*`, `KeyReservation.declaration!/5`, `derive!`), а что не
  сверяет никто;
- рёбра компиляции у `fixtures/consumer` (агрегат счёта). По возможности — фактом из
  `mix xref graph --label compile`, а не чтением.

Итог — таблица и граф в ответе тикета. Решений тикет не принимает.

## Answer

Снято с кода на 2026-10-23 (`lib/core/es/**`) и с `fixtures/consumer`, агрегат счёта.

### Два вида рёбер

- **Ожидание загрузки** — модуль нужен при раскрытии `use` или в теле модуля: `Code.ensure_compiled(!)`
  (`Helper.Opts.module!` зовёт его на каждой опции-модуле), вызов `__es_*__` / `__codec_*__`, struct-паттерн
  `%Mod{}` в голове. Взаимное ожидание здесь — тупик сборки.
- **Ребро `mix xref --label compile`** — только перекомпиляция. У фикстуры **все** compile-рёбра — алиасы
  в опциях `use` (`Macro.expand_literals(opts, __CALLER__)` в теле модуля), проверено
  `mix xref trace`. Рефлексивные чтения (`aggregate.__es_event_codec__()`, `codec.__es_mods__()`,
  `Code.ensure_compiled` внутри макроса) в xref **не видны**.

### Таблица

| Билдер | Опции связей | Ждёт при раскрытии / в теле | Хуки | Литералы в сгенерированном | Сверка | Не сверяет никто |
|---|---|---|---|---|---|---|
| `Es.Event` | `aggregate_id:`, `by:`, `payload:` | `payload` (`check_subject!`), `AggID` и `By` (struct в голове `new`) | — | `@type t` (`AggID.t()`, `By.t()`, `Payload.t()`); головы `new/5,6` `%AggID{}`, `%By{}`, `draft(%Payload{})`; `@spec new`, `@spec draft` | `subject: :aggregate_id` требует UUID-Prim (`check_subject!`) | — (одинаковость по событиям — у кодека) |
| `Es.Event.Codec` | `event:` (семейство), `type:`, `tags:`, `upcasts:` | семейство (`module!`); каждое событие из `tags:` (`ensure_compiled!` + `__es_payload__`, `__es_aggregate_id__`, `__es_by__`); нагрузки | `@before_compile`: ручной `dump/load` нагрузки, `upcast/2` при непустых `upcasts:` | `@type event :: Family.t()`; `load(@es_event, …)` | `derive!`: `__es_aggregate_id__` и `__es_by__` одинаковы у всех событий → `__es_aggregate_id__/0`; `@es_by` наружу не отдаётся | что события `tags:` входят в семейство `event:` (семейство — только `@type t`, интроспекции нет) |
| `Es.Aggregate` | `event_codec:` | ничего (`Helper.Opts.atom!`, ADR-0014 «Полнота») | `@after_compile`: `id`, `version` в struct | головы `%__MODULE__{}` (`fold`, `execute`) | — | что `event_codec:` — кодек этого агрегата (проверяет только `Repo`/`Repo.Pg`, если они есть) |
| `Es.Aggregate.Repo` (behaviour) | `aggregate:`, `id:` | агрегат (`exports: __es_event_codec__`), кодек (`event_codec!`), события и нагрузки (паттерны `evolve_checks`), `id` | — | `@callback` с `Id.t()` / `Agg.t()`; `__es_aggregate_repo__/0` = `%{aggregate, id}` | агрегат экспортирует `__es_event_codec__`; кодек с `type:`; полнота `evolve/2` | `id:` против `__es_aggregate_id__` кодека (тикет ревью 13) |
| `Es.Aggregate.Repo.Pg` | `behaviour:`, `aggregate:`, `id:`, `errors:`, `outbox:`, `key_reservations:` (+ `repo:`, `codec:`, `snapshot:`) | агрегат (`__es_event_codec__`, `fold/2`), кодек, `id`, `errors`, outbox, behaviour (`behaviour_info`), модули ключей | — | `@behaviour B`; головы `%Id{}` (`get`, `get_decision`, `page_stream`), `%Agg{}` (`refresh`, сужение результата) | `ensure_aggregate_id!` (`id:` ↔ кодек); `ensure_outbox_event!` (outbox `__es_event__` ↔ `__codec_union__`); `ensure_version_mismatch!`; behaviour — набор колбэков; `KeyReservation.declarations!` (семейство, `id:`, `code:` в `errors`, уникальность `scope`); полнота `reservation/1` (`KeyReservation.checks`) | `aggregate:` / `id:` против `behaviour.__es_aggregate_repo__()` (тикет ревью 13) |
| `Es.Aggregate.Process` | `repo:` (behaviour) | behaviour (`__es_aggregate_repo__`) → агрегат → кодек (`__es_type__`, `__es_subjects__`) | — | `@spec execute(Id.t(), …)`, голова `%Id{}` | behaviour экспортирует `__es_aggregate_repo__/0` | `id` берётся из behaviour без сверки с кодеком (тикет ревью 13); реализация — `Core.Config.repo!/1` во время выполнения |
| `Es.KeyReservation` | `event:`, `id:` (+ `scope:`, `code:`, `personal:`) | семейство и `id` (`module!`) | — | `find/2`: `@spec … :: Id.t() \| nil`, сужение `%Id{}` | только форма опций; всё остальное — у `Repo.Pg` | `event:` вне `Repo.Pg` ни для чего не используется — только для сверки; модуль ключа без репозитория не сверяется |
| `Es.Outbox` | `event:` (+ `topic:`, `codec:`) | семейство (`module!`) | — | `@type event :: Family.t()` в спеках `from_events/1`, `from_event/1`; `__es_event__/0` | `Repo.Pg` и `Repo.Pg.StateStored` (`ensure_outbox_event!`) | во время выполнения `event:` не нужен (конверт строит фасад) |
| `Es.Projection` | `events:` (модули событий) (+ `name:`, `version:`, `personal:`, `repo:`, `codec:`) | события; кодек по имени `<Family>.Codec` (`Module.concat`), `__es_mods__`, `__es_subjects__`, `__es_type__` | `@before_compile`: `project/1`, `clear/0`, `await/3,4`, проверки `project/1` | `await(Agg, %Id{} …)`: `Agg` — `Module.concat(split(codec) -- 2)`, атом без загрузки; `Id` — `codec.__es_aggregate_id__()` | событие в `tags:` своего кодека; один кодек на `type`; ПДн (`KeyDestroyed` / `personal: false`) | что `Agg` существует и что `Agg.__es_event_codec__() == codec`; семейство и кодек находятся только соглашением об именах |
| `Es.EventCompatCase` | `aggregate:` \| `event_codec:` (ровно одна) | агрегат → кодек (`__es_type__`, `__es_upcasts__`, `__es_subjects__`) | — | нет: кодек уходит атомом в проверки времени выполнения | ровно одна опция; экспорты кодека | — (агрегат здесь — только указатель на кодек) |

### Счёт повторов у агрегата счёта

- `Account.ID`: 5 событий (`aggregate_id:`), `Repo`, `Repo.Pg`, `NameKey`, `HolderKey` — 9.
- `Account.Event` (семейство): кодек, `Outbox`, `NameKey`, `HolderKey` — 4.
- `Account`: `Repo`, `Repo.Pg` — 2. `Account.Repo`: `Repo.Pg` (`behaviour:`), `Process` (`repo:`).
- Кодек: только агрегат (`event_codec:`); остальные билдеры получают его рефлексией через агрегат
  (`Repo`, `Repo.Pg`, `Process`, `EventCompatCase`) или по имени (`Projection`).

### Граф фикстуры

Ожидание загрузки (стрелка — «ждёт»; файл `account.ex` содержит и `Account`, и `Account.ID`):

```
Account                 → (ничего: event_codec: — атом)
Account.ID              → (Prim, ничего)
Event.<X>               → Account.ID, UserID, Event.<X>.Payload
Event (семейство)       → (только @type)
Event.Codec             → Event, Event.<X> ×5, нагрузки
Repo (behaviour)        → Account → Event.Codec → Event.<X>; Account.ID
Repo.Pg                 → Account, Event.Codec, Account.ID, Errors, Outbox, Repo, NameKey, HolderKey
Process                 → Repo → Account → Event.Codec
NameKey / HolderKey     → Event, Account.ID
Outbox                  → Event
Activity.Projection     → Event.<X>, Event.Codec (по имени), Account.ID (через кодек)
```

Взаимного ожидания нет только потому, что `Account` не ждёт кодек (ADR-0014, «Полнота»).

`mix xref graph --label compile` (перекомпиляция), фрагмент:

```
account.ex          → account/event/codec.ex            # алиас в event_codec:
account/event/*.ex  → account.ex, values/user_id.ex     # aggregate_id:, by:
account/event/codec.ex → account/event.ex, account/event/*.ex ×5
account/repo.ex     → account.ex
account/repo/pg.ex  → account.ex, errors.ex, outbox.ex, repo.ex, name_key.ex, holder_key.ex
account/process.ex  → account/repo.ex
account/name_key.ex, holder_key.ex → account.ex, account/event.ex
account/outbox.ex   → account/event.ex
activity/projection.ex → account/event/{opened,renamed,holder_set,closed}.ex, order/event/placed.ex
```

`mix xref graph --format cycles --label compile` у фикстуры — 4 цикла, по одному на агрегат с кодеком:
`Agg → Agg.Event.Codec → Agg.Event.<X> → Agg` (у счёта длина 7). Это цикл перекомпиляции, а не
ожидания: ребро `Agg → кодек` даёт алиас в `event_codec:`, а кодек агрегат не грузит.

### Факты для следующих тикетов

- Опции, которые нужны **только** для сверки: `id:` у `Repo.Pg` и `KeyReservation`, `aggregate:` у
  `Repo.Pg`, `event:` у `KeyReservation`. `event:` у `Outbox` нужен ещё для `@type event`.
- Опции, без которых пропадёт литерал по ADR-0014: `id:` у `Repo` (`@callback`, а через него
  голова `Process.execute`), `aggregate_id:` / `by:` у события (головы `new`), `event:` у `Outbox`
  (`@type event`), `id:` у `KeyReservation` (`find/2`). Литерал можно получить и рефлексией при
  раскрытии — так `Repo.Pg` и `Process` уже делают.
- Кодек — единственный модуль, который сейчас знает и id, и семейство, и тип, и события; он не знает
  агрегат и `by` наружу не отдаёт. Агрегат знает кодек, но не грузит его.
- Семейство `<Aggregate>.Event` — пустой модуль с `@type t`; на него указывают кодек, `Outbox`, ключи,
  но ни одна сверка не проверяет, что события кодека в него входят.
- Рефлексивные связи xref не видит: правильность перекомпиляции `Repo` / `Repo.Pg` / `Process` после
  правки кодека держится на транзитивном ребре `account.ex → кодек` от алиаса в `event_codec:`.
  Связь «агрегат → кодек» без литерала в `use` агрегата это ребро потеряет.
