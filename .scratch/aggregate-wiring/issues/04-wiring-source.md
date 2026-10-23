# 04: Единственный источник связей и направление ссылок

Type: grilling
Status: resolved

Blocked by: 03

## Question

Какой модуль — единственный источник связей агрегата (id, by, тип, семейство, кодек, сам агрегат), и кто на
него указывает?

Кандидаты хаба:
- кодек: уже знает `__es_aggregate_id__`, `__codec_union__`, `__es_type__`;
- behaviour репозитория: `__es_aggregate_repo__`;
- семейство из тикета 02;
- новый модуль.

Итог:
- хаб;
- направление ссылок у `Es.Aggregate.Repo`, `Repo.Pg`, `Process`, `EventCompatCase`;
- какие опции у них уходят (`id:`, `aggregate:`), какие остаются и почему (литералы ADR-0014);
- рёбра компиляции. Новые рёбра проверяются прототипом, если тикет 03 их не покрыл.

## Answer

Решено в обсуждении 2026-10-23.

**Хаба нет — цепочка с одним владельцем на факт.**
- Семейство владеет `aggregate_id` и `by` (тикет 02).
- Кодек владеет семейством, `type` и событиями.
- Агрегат — единственный, кто называет кодек (`event_codec:`, атом без загрузки, ADR-0014 «Полнота»).

Билдеры агрегата указывают на агрегат или на behaviour, который указывает на агрегат. Остальное они берут
рефлексией при раскрытии `use` и запекают литералами ADR-0014.

Отвергнуты:
- behaviour репозитория как хаб: не нужен `Projection`, `EventCompatCase`, `KeyReservation`, `Outbox`, а у
  агрегата без репозитория его нет;
- модуль-манифест `<Aggregate>.Wiring`: лишний файл, и он ждёт кодек теми же рёбрами;
- кодек как хаб: `Repo` / `Repo.Pg` всё равно нужен агрегат (`%Agg{}`, `fold`), и опций стало бы две.

Обратная ссылка «кодек → агрегат» здесь не вводится: её требует только `Projection`.

**Направление ссылок и опции.**

| Билдер | Было | Стало | Откуда значение |
|---|---|---|---|
| `Es.Aggregate` | `event_codec:` | без изменений | — |
| `Es.Aggregate.Repo` | `aggregate:`, `id:` | `aggregate:` | `id` — `aggregate.__es_event_codec__().__es_aggregate_id__()`; литерал в `@callback` и `__es_aggregate_repo__/0` (`%{aggregate, id}`) |
| `Es.Aggregate.Repo.Pg` | `behaviour:`, `aggregate:`, `id:`, … | `behaviour:`, … | `behaviour.__es_aggregate_repo__()`; головы `%Id{}` / `%Agg{}` из него |
| `Es.Aggregate.Process` | `repo:` | без изменений | уже из `__es_aggregate_repo__/0` |
| `Es.EventCompatCase` | `aggregate:` \| `event_codec:` | без изменений | `event_codec:` нужен state-stored (нет `use Core.Es.Aggregate`) |
| `Es.Event.Codec` | `event:` | `family:` | имя, как у события (тикет 02) |
| `Es.Outbox` | `event:` | `family:` | `@type event` из семейства; подходит и state-stored |

У `Repo.Pg` остаются `errors:`, `outbox:`, `key_reservations:`, `repo:`, `codec:`, `snapshot:`.

- Из `Repo.Pg` уходит вызов `ensure_aggregate_id!`: сверять больше не с чем. Сама функция остаётся у
  `Repo.Pg.StateStored` (поправка тикета 05).
- Сверки тикета ревью 13 уходят вместе с опциями этого выпуска.

**Рёбра компиляции.**
- Новых ожиданий нет: `Repo`, `Repo.Pg`, `Process` уже ждут агрегат и кодек.
- Из xref уходят прямые рёбра от алиасов `id:` / `aggregate:`.
- Перекомпиляция держится на транзитивных рёбрах `repo/pg.ex → repo.ex → account.ex → codec` и на
  struct-паттернах сгенерированного кода. Проверяет тикет 05.
