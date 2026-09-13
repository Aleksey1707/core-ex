# Контракт state-stored агрегата поверх общей таблицы событий

Type: grilling
Status: resolved
Blocked by: 06, 07
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как state-stored агрегат пишет в общую таблицу событий `es_events` и читает из неё:

- что остаётся на агрегат от `Es.Event.Repo`, `Es.Event.Repo.Pg` и `Es.Event.Repo.Pg.Schema`, а что берётся из
  хранилища событий event-sourced агрегата;
- что меняется в `use Core.Repo.Pg.Es` и в порядке flush (`Outbox.from_events` → `Event.Repo.append` →
  `Outbox.Repo.append`);
- что для usecase state-stored значит новый источник `:version_mismatch` — проверка `xid` при append;
- какие ломающие изменения и какая инструкция переноса истории уходят в `CHANGELOG.md` (было → стало).

## Answer

- **Хранилище событий.** Триплет `Core.Es.Event.Repo{,.Pg,.Pg.Schema}` и модули `<Agg>.Event.Repo{,.Pg,.Pg.Schema}`
  уходят: state-stored пишет через `Core.Es.Store.append`, как event-sourced. `event_repo:` и её DI через `Config.repo!`
  уходят, подмена — только `<Agg>.Repo`. `list_by_aggregate` (с `:from_version` / `:to_version`), `count_by_aggregate`,
  `page_by_aggregate` удаляются; история для экрана — read-путь.
- **Builder.** `Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored` — пара к `Core.Es.Aggregate.Repo.Pg`;
  `Core.Repo.Pg.Events` отвергнуто — читается как репозиторий событий. `event_repo:` → обязательная `event_codec:`,
  источник типа агрегата. На компиляции — `CompileError`, если кодек без `type:`, Prim `__es_aggregate_id__/0` кодека не
  равен `id:`, `event:` у `outbox:` (интроспекция `__es_event__/0` у `Es.Outbox`) не равен семейству кодека, в `errors:`
  нет `:version_mismatch`. Событие не из `tags:` кодека — `FunctionClauseError`.
- **Порядок записи** прежний, в одном `Transact.run`: строка → дочерние строки → `outbox.from_events` →
  `Core.Es.Store.append` → `outbox_repo().append`; wake проекций — из `append` хранилища после commit. `Repo.Sc`,
  `shadow_copy?` и `check_events_for_change!` не меняются.
- **Проверки append.** У state-stored — unique `(тип, aggregate_id, aggregate_version)` и страж `xid`. Непрерывность
  потока (первая версия пачки = `max + 1`, версии подряд внутри пачки) — опция `Store.append`, её включает только
  `Core.Es.Aggregate.Repo.Pg`: поток state-stored законно начинается не с 1 и имеет разрывы (агрегат создан без события,
  события появились позже, мутация без события).
- **`:version_mismatch`** — тот же код из `errors:`, ns — `behaviour:` write-репо, detail `%{aggregate_id, expected,
  actual}`: `expected` — первая версия потока в пачке, `actual` — `max` версии потока отдельным `SELECT` только на пути
  ошибки. Отказ стража `xid` отдельного кода не получает: реакция одна — повторить usecase, `get` заново сверит версию
  клиента; хелпера повтора нет.
- **`type:`** обязателен у любого `use Core.Es.Event.Codec`, формат — как у wire-тега; дубль среди плагинов фасада —
  `CompileError` в `use Core.Codec.Facade`. Связь `type:` с префиксом тега не проверяется: записанные теги неизменяемы.
- **Перенос истории.** Выпуск — с остановкой записи state-stored агрегатов. Миграции потребителя по порядку:
  делегирующая `defdelegate up/down, to: Core.Es.Migration`; копия `INSERT INTO es_events … SELECT … ORDER BY
  aggregate_id, aggregate_version` по каждой таблице (`down` — `DELETE FROM es_events WHERE type IN (…)`); удаление
  старых таблиц — после проверки. Триггер на старых таблицах без простоя отвергнут: транзакция старой ноды получает
  `xid` меньше копии.
- **`CHANGELOG.md`.** «Ломающие изменения контракта»: общая таблица и три миграции с SQL-шаблоном; удалённый триплет и
  его чтения, подмена `<Agg>.Event.Repo` в app-env; ns, detail и новый источник `:version_mismatch`; Ecto-тип для
  `payload_type:` и схема для `by_schema:` не нужны, FK `by_id` нет. «Изменения контракта макросов»:
  `Core.Repo.Pg.StateStored` с `event_codec:` и сверками; обязательный `type:` и его дубль в фасаде.
- Своды и README — «Своды» в карте. ADR не заводится: компромисс общей таблицы — ADR-0008, остальное откатывается
  дёшево. `CONTEXT.md` не меняется.

## Comments

- 2026-09-13 — из тикета [«Контракт репозитория event-sourced агрегата»](07-grilling-repo-contract.md): у event-sourced агрегата хранилище событий —
  модуль библиотеки `Core.Es.Store`, триплета `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` нет — рассмотреть то же для
  state-stored; builder event-sourced репозитория — `Core.Es.Aggregate.Repo{,.Pg}`, имя `Core.Repo.Pg.Es` путается с
  event-sourced — переименование решается здесь; проверка непрерывности потока (`max + 1`) живёт в `append` хранилища —
  если state-stored пишет через тот же модуль, она действует и на него.
- 2026-09-13 — из тикета [«Проекции: источник событий, чекпоинт, порядок»](08-grilling-projections.md): проекции
  объявляют события state-stored агрегатов наравне с event-sourced — нужен `type:` у их кодека событий; читатель
  фильтрует по типу агрегата (индекс `(тип, xid, номер)` в `Core.Es.Migration`); `append` хранилища после commit
  будит читателей проекций через `AfterCommit`.
- 2026-09-13 — из тикета [«Эволюция событий: где апкастится история»](09-grilling-event-evolution.md): перенос таблиц
  событий state-stored в `es_events` — копирование без преобразования нагрузки и тегов; старые формы читает апкаст
  кодека (`upcasts:` + `upcast/2`), он действует и на state-stored агрегаты.
- 2026-09-13 — из тикета [«Снапшоты: хранение, политика, инвалидация»](10-grilling-snapshots.md): `Core.Es.Store`
  получает чтение потока после версии (хвост за снапшотом); неиспользуемые `:from_version` / `:to_version` в
  `Es.Event.Repo.Pg.list_by_aggregate` решаются здесь вместе с судьбой триплета; `es_snapshots` state-stored не касается.
- 2026-09-13 — раунд 1:
  - триплет `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` уходит, как у event-sourced: builder write-репо зовёт
    `Core.Es.Store.append` напрямую; `event_repo:` и её DI через `Config.repo!` уходят; проверка clause
    `:version_mismatch` в `errors:` — в builder; `list_by_aggregate` (с `:from_version` / `:to_version`),
    `count_by_aggregate`, `page_by_aggregate` уходят, история для экрана — read-путь; порядок записи прежний:
    `outbox.from_events` → `Core.Es.Store.append` → `outbox_repo().append`, wake проекций — из `append` хранилища;
  - непрерывность потока (первая версия пачки = `max + 1`, версии подряд внутри пачки) — только у event-sourced: опция
    `Store.append`, её включает `Core.Es.Aggregate.Repo.Pg`; у state-stored — unique и страж `xid`: поток законно
    начинается не с 1 и имеет разрывы (агрегат создан без события, события появились позже, мутация без события);
  - `type:` обязателен у любого `use Core.Es.Event.Codec`, формат — как у wire-тега; дубль `type:` среди плагинов фасада
    — `CompileError` в `use Core.Codec.Facade`;
  - `Core.Repo.Pg.Es` переименовывается в `Core.Repo.Pg.StateStored` — термин `CONTEXT.md`, пара к
    `Core.Es.Aggregate.Repo.Pg`; `Core.Repo.Pg.Events` отвергнуто — читается как репозиторий событий;
  - `:version_mismatch` на append у state-stored — тот же код из `errors:`, ns — `behaviour:` write-репо, detail — форма
    `Core.Es.Store` (`%{aggregate_id, expected, actual}`) вместо `%{aggregate_id, versions}`; отказ стража `xid`
    отдельного кода не получает — реакция одна: повторить usecase, `get` заново сверит версию клиента; хелпера повтора
    нет;
  - выпуск — с остановкой записи state-stored агрегатов: DDL `Core.Es.Migration` и копия `INSERT INTO es_events … SELECT
    … ORDER BY aggregate_id, aggregate_version` по каждой таблице; старые таблицы — отдельной миграцией после проверки;
    `CHANGELOG.md` даёт SQL-шаблон и ломающие правки было → стало; триггер на старых таблицах без простоя отвергнут —
    транзакция старой ноды получает `xid` меньше копии.
- 2026-09-13 — раунд 2:
  - тип агрегата для `Store.append` — обязательная опция `event_codec:` у `use Core.Repo.Pg.StateStored` (как `use
    Core.Es.Aggregate, event_codec:`), проверка на компиляции — кодек событий с `type:`; событие не из его `tags:` —
    `FunctionClauseError`; вывод из `outbox:`, через фасад и опция `codec:` у каждого `use Es.Event` отвергнуты;
  - связь `type:` и wire-тега не проверяется: записанные теги неизменяемы, префикс сломал бы их и источники `upcasts:`;
    квалификация тега именем агрегата — соглашение `14-events-outbox.md`;
  - detail `:version_mismatch` у state-stored: `expected` — первая версия потока в пачке, `actual` — `max` версии потока
    отдельным `SELECT` только на пути ошибки; форма одна у обоих видов агрегатов;
  - перенос — две миграции потребителя: делегирующая `defdelegate up/down, to: Core.Es.Migration` (как у потребителя без
    истории) и следующая по timestamp копия `INSERT INTO es_events … SELECT … ORDER BY aggregate_id, aggregate_version`
    с `down` — `DELETE FROM es_events WHERE type IN (…)`; обе — одним `mix ecto.migrate` до старта нового кода; старые
    таблицы — третьей миграцией после проверки.
- 2026-09-13 — раунд 3:
  - `use Core.Repo.Pg.StateStored` сверяет на компиляции Prim `__es_aggregate_id__/0` кодека с `id:` и `event:` у
    `outbox:` (интроспекция `__es_event__/0` у `Es.Outbox`) с семейством кодека — `CompileError`;
  - состав `CHANGELOG.md` — как в ответе; ADR не заводится.
