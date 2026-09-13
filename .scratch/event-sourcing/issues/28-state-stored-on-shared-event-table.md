# 28: State-stored агрегат на общей таблице событий

**What to build:** разработчик state-stored агрегата переходит с `use Core.Repo.Pg.Es, event_repo:` на
`use Core.Repo.Pg.StateStored, event_codec:`: события пишутся в `es_events` через `Core.Es.Store.append` в прежнем
порядке, модули событий на агрегат (`<Agg>.Event.Repo{,.Pg,.Pg.Schema}`) больше не нужны. Старый builder и триплет
`Core.Es.Event.Repo{,.Pg,.Pg.Schema}` удаляются; `CHANGELOG.md` описывает ломающие правки и перенос истории.

**Blocked by:** [26: Хранилище событий](26-event-store-append.md), [27: Страница потока](27-stream-page.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «State-stored агрегат поверх общей таблицы»

- [ ] `Core.Repo.Pg.Es` переименован в `Core.Repo.Pg.StateStored`; `event_repo:` заменена обязательной `event_codec:`.
- [ ] `CompileError`: кодек без `type:`; Prim `__es_aggregate_id__/0` кодека не равен `id:`; `event:` у `outbox:`
      (новая интроспекция `Es.Outbox.__es_event__/0`) не равен семейству кодека; в `errors:` нет `:version_mismatch`.
      Событие не из `tags:` кодека — `FunctionClauseError`.
- [ ] Порядок записи в одном `Transact.run`: строка → дочерние строки → `outbox.from_events` → `Core.Es.Store.append`
      без непрерывности потока → `outbox_repo().append`; `Repo.Sc`, `shadow_copy?` и `check_events_for_change!` не
      меняются.
- [ ] `:version_mismatch` на записи событий — код из `errors:`, ns — `behaviour:`, detail
      `%{aggregate_id, expected, actual}`.
- [ ] Удалены `Core.Es.Event.Repo`, `Core.Es.Event.Repo.Pg`, `Core.Es.Event.Repo.Pg.Schema` вместе с
      `list_by_aggregate`, `count_by_aggregate`, `page_by_aggregate`, их тестами и ссылками в `Core.Config`, `Core.DAO`
      и `Repo.Pg.Children`.
- [ ] `Entity` / `Child` из теста `Repo.Pg.Es` переехали в `test/support` (таблицы — в тестовых миграциях, кодек —
      `Core.EventFixture`); тесты: поток не с 1 и с разрывами, мутация без события, конфликт стража `xid` у
      state-stored, записанные события через `Core.Es.Store.Test.events!/2`.
- [ ] `CHANGELOG.md`, «Ломающие изменения контракта» — дополнить существующие пункты про `Es.Event.Repo.Pg.Schema`, а
      не заводить параллельные:
  - общая таблица и выпуск с остановкой записи state-stored агрегатов;
  - три миграции потребителя с SQL-шаблоном: делегирующая `Core.Es.Migration`; копия
    `INSERT INTO es_events … SELECT … ORDER BY aggregate_id, aggregate_version` по каждой старой таблице без
    преобразования тегов и нагрузки (`down` — `DELETE` по типу агрегата); удаление старых таблиц — после проверки.
    В шаблоне колонка тега старой таблицы (`type`) и колонка типа агрегата `es_events` разведены;
  - удалённый триплет и подмена `<Agg>.Event.Repo` в app-env;
  - `@event_repo.page_by_aggregate(id, limit, offset, context)` →
    `Core.Es.Store.page_stream(Agg.Event.Codec, id, limit, offset, context)` и норма проверки доступа до чтения;
    `list_by_aggregate` в тестах → `Core.Es.Store.Test.events!/2`;
  - ns, detail и новый источник `:version_mismatch` (страж `xid`);
  - Ecto-тип для `payload_type:`, схема для `by_schema:` и FK `by_id` больше не нужны.
- [ ] `CHANGELOG.md`, «Изменения контракта макросов»: `Core.Repo.Pg.StateStored` с `event_codec:` и сверками.
- [ ] Своды:
  - `13-repos.md` — «Write state-stored агрегата (`use Core.Repo.Pg.StateStored`)», таблица опций сохраняется;
    «Role Repo vs common Repo.Pg» без `Event.Repo` и абзаца «Чтение истории»; раздел «Event store» удалён, в
    «Хранилище событий» — `Core.Es.Store.append` MUST NOT вне write-builder'ов, MAY — тестовые дублёры; «Слои и пути»
    без `event/repo`; «Schema», «Тесты», шапка;
  - `14-events-outbox.md` «Domain events» — flush через `Core.Es.Store.append`, источники `:version_mismatch`;
  - `10-architecture.md`, `00-index.md` и `20-agreements.md` (исключения `@spec`, «Safe vs bang») — новые имена;
    `12-errors.md` «Источники `%Error{}`» — `Core.Es.Store`;
  - `DEBT.md` — переименование `Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored`, новых строк нет.
- [ ] README: «Что предоставляет потребитель» без пункта про Ecto-тип jsonb, новые имена модулей; `description` skill
      `repos`. ADR не правятся.
- [ ] `make` зелёный, включая `boundary-check` и `xref`.
