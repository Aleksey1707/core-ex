# 06: Откуда модуль ключа берёт семейство и id

Type: grilling
Status: resolved

Blocked by: 04

## Question

`use Core.Es.KeyReservation` повторяет `event:` и `id:`. `event:` нужен только для сверки в `Repo.Pg`, а `id:` —
для литерала в `find/2`. При цепочке тикета 04 (агрегат → кодек → семейство) на что указывает модуль ключа и
какие опции у него уходят?

Решение учитывает:
- `Repo.Pg` ждёт модули ключей (`key_reservations:`); ссылка ключа на репозиторий или агрегат не должна
  создать взаимного ожидания;
- полноту `reservation/1`: где её проверять, если модуль ключа без репозитория не сверяется (кандидат ревью
  `.scratch/builders-review/issues/10-key-reservation-completeness.md`).

## Answer

Решено в обсуждении 2026-10-23.

**Ссылка ключа — `aggregate:`.** `use Core.Es.KeyReservation`: `scope:`, `aggregate:`, `code:`, `personal:`;
`event:` и `id:` уходят. При раскрытии `use` ключ берёт кодек рефлексией
(`aggregate.__es_event_codec__()`), из кодека — семейство и `__es_aggregate_id__()`, и запекает id литералом в
`find/2` и его `@spec` (ADR-0014).

Отвергнуты:
- `event_codec:` — короче на шаг, но кодек называет только агрегат (тикет 04);
- `repo:` (behaviour) — лишняя ступень, а `Repo.Pg` сам ждёт ключи.

Взаимного ожидания нет: агрегат ключ не называет, кодек агрегат не называет, `Repo.Pg` ждёт и агрегат, и ключ.
Ребро ключ → агрегат новое — проверяет тикет 08.

**Полнота `reservation/1` — в модуле ключа.** Функции-проверки `Es.Check` генерирует `use` ключа по событиям
кодека, а не `Repo.Pg`: предупреждение указывает на ключ, ключ проверяется и без репозитория — как `project/1` у
`Projection`. Соглашение об именах для поиска кодека (кандидат ревью 10) не нужно. Ревью
`.scratch/builders-review/issues/10-key-reservation-completeness.md` поглощено этим решением.

**Сверки `Repo.Pg`.** Сверки семейства и `id:` заменяет одна: агрегат ключа равен агрегату из
`behaviour.__es_aggregate_repo__()` — ловит ключ чужого агрегата. Остаются clause `code:` в `errors:` и
уникальность `scope`. `Es.KeyReservation.checks/3` из `Repo.Pg` уходит.

| Билдер | Было | Стало |
|---|---|---|
| `Es.KeyReservation` | `scope:`, `event:`, `id:`, `code:`, `personal:` | `scope:`, `aggregate:`, `code:`, `personal:` |
| `Es.Aggregate.Repo.Pg` | сверка `event:` / `id:` ключа, полнота `reservation/1` | сверка агрегата ключа |
