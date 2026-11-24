# 01: Монотонные v7-Prim: замена генератора

**What to build:** все идентификаторы, объявленные через `use Core.Prim.UUID, version: 7`, выдают
строго возрастающие значения в пределах ноды. Потребитель не пишет код: генератор меняется в
единственной точке `Core.Prim.UUID.generate(7)`, а `Outbox.ID`, `Outbox.LeaseID`, `Es.Event.ID`,
`Es.Event.OperationID` и объявленные потребителем v7-Prim получают монотонность вместе с
зависимостью `uuid_v7 ~> 0.6.0` (вместо `uuidv7 ~> 1.0`). Регрессия закреплена тестами на двух
существующих швах: v7-Prim и `Es.Event.ID`. Документация `Prim.UUID` и свода `11-domain.md`
называет гарантию, `CHANGELOG.md` тем же коммитом объявляет новое поведение и ломающие
изменения транзитивного пакета.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Зависимость `uuidv7 ~> 1.0` заменена на `uuid_v7 ~> 0.6.0`; lock-файл обновлён и не
      содержит `uuidv7`; `Core.Prim.UUID.generate(7)` по-прежнему зовёт `UUIDv7.generate/0`,
      правок в объявлениях v7-Prim нет.
- [x] `Core.Prim.UUIDTest`: 10 000 последовательных `new()` объявленного в тесте v7-Prim строго
      возрастают и уникальны; тест детерминированно падает на старой зависимости и проходит на
      новой.
- [x] `Core.Es.EventTest`: 10 000 `Es.Event.ID.new()` строго возрастают.
- [x] `@moduledoc` `Core.Prim.UUID` и свод `11-domain.md` (раздел о `Prim.UUID`) говорят, что
      `version: 7` монотонен в пределах ноды.
- [x] `CHANGELOG.md` в том же коммите: «Новое» — монотонные v7-Prim и tiebreaker outbox по
      порядку вставки; «Ломающие изменения контракта» — `UUIDv7` больше не `Ecto.Type`
      (`UUIDv7.Type`), `timestamp/1` → `extract_timestamp/1`, timestamp-формы `generate/1` и
      `bingenerate/1` удалены.
- [x] `UUIDv7.Type` присутствует в собранной зависимости; `make consumer-check` это подтверждает.
- [x] `make` зелёный целиком, включая `consumer-check`, `dialyzer` и `audit`.

## Comments

Реализовано на `feat/uuid-v7-monotonic`: `e9c0e9a` (`uuid: switch to uuid_v7 and assert v7 monotonicity`), правки code-review — `432e1dc`.

- `mix.exs` / `mix.lock`: `uuid_v7 ~> 0.6.0`, записи `uuidv7` в lock нет; `Core.Prim.UUID.generate(7)` не менялся, объявления v7-Prim не тронуты.
- Тесты порядка: `Core.Prim.UUIDTest` — 10 000 `new()` объявленного в тесте v7-Prim; `Core.Es.EventTest` — 10 000 `Es.Event.ID.new()`; оба `async: true` без БД.
- `UUIDv7.Type` присутствует в собранной зависимости (`Code.ensure_loaded?/1` → `true`), `make consumer-check` зелёный.
- Доказательство регрессии: временный возврат `{:uuidv7, "~> 1.0"}` + `mix deps.get` — падают ровно тесты порядка `Core.Prim.UUIDTest` и `Core.Es.EventTest` (49/51); после восстановления `uuid_v7` — 51/51.
- Приёмка: полный `make` зелёный на `432e1dc` (boundary, rules, layout, spec, format, compile, compile-no-optional, consumer-check, deps-clean, xref, dialyzer, test, credo, audit); `mix test` — 3549 passed, 10 excluded.
