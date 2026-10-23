# 08: Прототип модуля ключа с `aggregate:`

Type: prototype
Status: resolved

Blocked by: 06

## Question

Собирается ли `use Core.Es.KeyReservation` с `aggregate:` вместо `event:` / `id:` и проверкой полноты
`reservation/1` в самом ключе (тикет 06) на копии `fixtures/consumer`, и правильна ли перекомпиляция с новым
ребром ключ → агрегат?

- `make consumer-check` проходит; голова `find/2` ловит чужой id, как сейчас;
- неполный `reservation/1` даёт предупреждение в модуле ключа, а не в `use` репозитория;
- `Repo.Pg` с ключом чужого агрегата — `CompileError`;
- разница `mix xref graph --label compile`, цикл перекомпиляции агрегата;
- правка `Account.ID` и кодека перекомпилирует модули ключей.

Прототип — от ветки `prototype/repo-wiring`, ссылка на него — в ответе.

## Answer

Проверено 2026-10-23. Прототип — ветка `prototype/key-reservation-wiring` (коммит `6ebd7d0`, от `prototype/repo-wiring`
`670f7c9`), не сливается. Скрипт замера перекомпиляции — `.prototype/recompile.sh` на ней.

**Что в прототипе.**
- `Es.KeyReservation`: обязательны `scope:`, `aggregate:`, `code:`; `aggregate:` проверяется на `__es_event_codec__/0`,
  кодек — `Es.Store.Opts.event_codec!`, id — `__es_aggregate_id__/0` кодека. Функции-проверки
  `"reservation/1 принимает <Event>"` генерирует `use` ключа по `__es_mods__/0` кодека, тело — локальный вызов
  `reservation(event)`.
- `Es.Aggregate.Repo.Pg`: `checks/3` ушёл; `declarations!/4` сверяет агрегат ключа с агрегатом из `behaviour:`,
  clause `code:` в `errors:` и уникальность `scope`. `reservation: 1` из `exports:` модуля ключа убран.
- Фикстура: `event:` / `id:` → `aggregate: Account` у `NameKey`, `HolderKey` и двух ключей сценария; маркеры
  `# expect:` перенесены со строки `use` репозитория на строку `use` ключа. Moduledoc билдера не правился.

**Результат.**
- `make consumer-check` — ok, 126 ожидаемых предупреждений, лишних нет. `case_find_foreign_id` и `find_not_context`
  дают прежние предупреждения: литерал `%Account.ID{}` в `find/2` из кодека работает.
- Неполный `reservation/1` и опечатка в поле нагрузки — предупреждение на строке `use` ключа. Текст другой:
  `incompatible types given to reservation/1` (локальный вызов), а не `…BadKey.reservation/1`. Репозиторий для
  проверки больше не нужен — сценарии `BadKey.Repo.Pg` / `BadKeyPayload.Repo.Pg` в реализации можно убрать.
- `CompileError` (временный сценарий, не закоммичен):
  - ключ с `aggregate: Order` в `key_reservations:` репозитория счёта — `key_reservations: aggregate: …Order у
    …OrderKey не равен агрегату репозитория …Account`;
  - `aggregate:` не агрегат — `aggregate: модуль … должен экспортировать __es_event_codec__/0`;
  - старые `event:` / `id:` — `нет обязательных опций: [:aggregate]`: о снятых опциях текст не говорит
    (к режиму перехода).
- `mix xref graph --label compile`, разница — три ребра:

  ```
  - account/holder_key.ex        → account/event.ex   # event: Account.Event
  - account/name_key.ex          → account/event.ex
  - scenarios/key_reservation.ex → account/event.ex
  ```

  `<key>.ex → account.ex` (compile) было и до (`id: Account.ID` вложен в `account.ex`), теперь — от `aggregate:`.
  Рёбер ключ → кодек / события нет: кодек получен рефлексией. Циклы те же (8, 6, 4, 3).
- Перекомпиляция (`mix compile --verbose` после правки; база — `prototype/repo-wiring`): наборы совпали во всех
  семи правках — `Account.ID` private / public, агрегат public, кодек private / public, семейство public, событие
  public. Каждая перекомпилирует `holder_key.ex`, `name_key.ex`, `account/repo/pg.ex`, `scenarios/key_reservation.ex`.
  Новое событие меняет кодек, поэтому проверки полноты в ключе пересобираются. Держится на ребре
  ключ → `account.ex`, который в цикле с кодеком, событиями и семейством.

**Для реализации.**
- `event:` / `id:` → `aggregate:` и в тестах библиотеки: `test/support/es_fixture/{account/holder_key,account/name_key,
  catalog/path_key}.ex`; тесты сверок `Repo.Pg` для `event:` / `id:` ключа переписываются на сверку агрегата. В
  прототипе не правились, `mix test` не запускался.
- `declaration` ключа несёт `aggregate`, `event_codec` и `id`; `event` уходит.
