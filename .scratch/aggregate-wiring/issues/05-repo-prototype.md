# 05: Прототип репозитория без `id:` / `aggregate:`

Type: prototype
Status: resolved

Blocked by: 04

## Question

Собираются ли `Es.Aggregate.Repo` с одной `aggregate:` и `Repo.Pg` без `aggregate:` / `id:` (тикет 04) на
копии `fixtures/consumer`, и остаётся ли перекомпиляция правильной без прямых xref-рёбер от этих алиасов?

- `make consumer-check` проходит, литеральные головы `%Id{}` / `%Agg{}` ловят чужой id, как сейчас;
- разница `mix xref graph --label compile`;
- правка `Account.ID` и кодека перекомпилирует `Repo`, `Repo.Pg`, `Process`. Отдельно — агрегат, у которого
  `Agg.ID` в отдельном файле, а не вложенным модулем.

Прототип — от ветки `prototype/family-declaration`, ссылка на него — в ответе.

## Answer

Проверено 2026-10-23. Прототип — ветка `prototype/repo-wiring` (коммит `670f7c9`, от `prototype/family-declaration`
`2374b70`), не сливается.

**Что в прототипе.**
- `Es.Aggregate.Repo`: обязательна только `aggregate:`; `id` —
  `Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), …).__es_aggregate_id__()`. Кодек и так грузился
  для проверок полноты `evolve`, новой загрузки нет.
- `Es.Aggregate.Repo.Pg`: обязательны `behaviour:`, `errors:`, `outbox:`; `behaviour:` проверяется на
  `__es_aggregate_repo__/0`, `%{aggregate, id}` берётся из него. Вызов `ensure_aggregate_id!` из `Repo.Pg` убран.
- Фикстура: `id:` / `aggregate:` сняты у четырёх `Repo` и двух `Repo.Pg`, в сценариях `evolve.ex` и
  `key_reservation.ex`. `Order.ID` вынесен в `order/id.ex` — агрегат с ID в отдельном файле.

**Результат.**
- `make consumer-check` — ok, 126 ожидаемых предупреждений, лишних нет. Сценарии `scenarios/repo.ex`
  (чужой id в `get` / `get_decision` / `append` / `refresh` / `page_stream`) дают те же
  `incompatible types given to …Repo.Pg.<f>/<n>`: литеральные головы из `__es_aggregate_repo__/0` работают.
- `mix xref graph --label compile`, разница — только два ребра:

  ```
  - account/repo/pg.ex → account.ex   # aggregate: / id: (Account.ID вложен в account.ex)
  - order/repo/pg.ex   → order.ex
  ```

  `repo.ex → account.ex` остаётся (вызов `__es_event_codec__/0` при раскрытии). Ребра `repo.ex → codec` нет ни
  до, ни после: кодек получен рефлексией. Ребро `repo/pg.ex → order/id.ex` — `export` (struct-паттерн головы).
  Цикл перекомпиляции не изменился.
- Перекомпиляция (`mix compile --verbose` после правки, база — `prototype/family-declaration` с тем же выносом
  `Order.ID`): наборы совпали во всех восьми правках.

  | Правка | База и прототип перекомпилируют |
  |---|---|
  | `Account.ID` — private / public функция | `account/repo.ex`, `account/repo/pg.ex`, `account/process.ex` |
  | кодек счёта — private / public функция | `account/repo.ex`, `account/repo/pg.ex`, `account/process.ex` |
  | `Order.ID` в `order/id.ex` — private / public функция, `name:` | `order/repo.ex`, `order/repo/pg.ex` |
  | кодек заказа — public функция | `order/repo.ex`, `order/repo/pg.ex` |

  Держится на транзитивных рёбрах `repo/pg.ex → repo.ex → <agg>.ex → codec / events → family → ID` (тикет 03:
  семейство и события compile-зависят от ID).

**Для реализации.**
- Поправка к тикету 04: `Es.Store.Opts.ensure_aggregate_id!` не удаляется — его зовёт `Repo.Pg.StateStored`
  (`state_stored.ex:261`), опции которого не меняются. Из `Repo.Pg` уходит только вызов.
- `id:` / `aggregate:` снимаются и в тестах библиотеки: `test/support/es_fixture/**/repo*.ex`,
  `test/core/macro_config_test.exs`, `test/core/es/personal/events_test.exs`,
  `test/core/es/aggregate/repo/pg/snapshotted_test.exs`. В прототипе не правились, `mix test` не запускался.
- Не проверено: `CompileError` при `behaviour:` без `__es_aggregate_repo__/0` — даёт `Helper.Opts.module!`
  с `exports:`, как у `Process`.
